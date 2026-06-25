<#
====================================================================
 New-EcoTechADUsers.ps1
 Création en masse des comptes AD EcoTechSolutions depuis la liste RH.
 --------------------------------------------------------------------
 - Lit le fichier collaborateurs.csv (export de la liste RH, séparateur ;)
 - Crée l'arborescence d'OU : OU=EcoTech > Utilisateurs > <Département>
 - Génère sAMAccountName = 1ère lettre du prénom + nom (gère les collisions)
 - Génère l'UPN prenom.nom@ecotech.local
 - Renseigne fonction, département, service, société, site, téléphones
 - Crée un groupe de sécurité global par département (GG_<Dept>)
 - Lie les managers en 2e passe
 - Idempotent : relançable sans créer de doublon
 - Exporte un rapport : rapport-comptes.csv

 A exécuter SUR le contrôleur de domaine, PowerShell en Administrateur.
====================================================================
#>

# ----------------------- PARAMÈTRES À ADAPTER -----------------------
$CsvPath     = ".\collaborateurs.csv"          # chemin du CSV
$Delimiter   = ';'
$DomainDN    = "DC=ecotech,DC=local"           # ton domaine
$UpnSuffix   = "ecotech.local"
$RootOuName  = "EcoTech"
$DefaultPwd  = "Ecotech2025!"                   # mot de passe initial (12+ car., complexe)
$ReportPath  = ".\rapport-comptes.csv"
# --------------------------------------------------------------------

Import-Module ActiveDirectory -ErrorAction Stop
$ErrorActionPreference = 'Stop'

# Mot de passe initial sécurisé (changé à la 1ère connexion)
$SecurePwd = ConvertTo-SecureString $DefaultPwd -AsPlainText -Force

# --- Fonctions utilitaires -----------------------------------------

# Retire les accents et caractères spéciaux pour les logins
function ConvertTo-Slug([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    $norm = $text.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($c in $norm.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne
            [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($c) }
    }
    # garde uniquement lettres et chiffres, en minuscules
    return ($sb.ToString() -replace '[^a-zA-Z0-9]', '').ToLower()
}

# Crée une OU si elle n'existe pas déjà (protégée contre suppression accidentelle)
function New-OuIfMissing([string]$Name, [string]$ParentDN) {
    $dn = "OU=$Name,$ParentDN"
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$Name'" -SearchBase $ParentDN -SearchScope OneLevel -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $Name -Path $ParentDN -ProtectedFromAccidentalDeletion $true
        Write-Host "  OU créée : $dn" -ForegroundColor DarkGray
    }
    return $dn
}

# --- 1. Arborescence d'OU de base ----------------------------------
Write-Host "`n[1] Vérification de l'arborescence d'OU..." -ForegroundColor Cyan
$rootOuDN  = New-OuIfMissing -Name $RootOuName            -ParentDN $DomainDN
$usersOuDN = New-OuIfMissing -Name "Utilisateurs"         -ParentDN $rootOuDN
$groupsOuDN= New-OuIfMissing -Name "Groupes"             -ParentDN $rootOuDN
$null      = New-OuIfMissing -Name "Ordinateurs"          -ParentDN $rootOuDN
$null      = New-OuIfMissing -Name "Serveurs"             -ParentDN $rootOuDN

# --- 2. Import du CSV ----------------------------------------------
Write-Host "[2] Import du CSV : $CsvPath" -ForegroundColor Cyan
$people = Import-Csv -Path $CsvPath -Delimiter $Delimiter -Encoding UTF8
Write-Host "    $($people.Count) collaborateurs à traiter."

# Tables de suivi
$usedSam   = @{}   # logins déjà attribués
$userByName= @{}   # "Prenom|Nom" -> DN (pour managers)
$deptGroups= @{}   # dept -> DN du groupe
$report    = @()   # lignes du rapport final
$created = 0; $skipped = 0

# --- 3. Passe 1 : OU département, groupes, utilisateurs -------------
Write-Host "`n[3] Création des comptes..." -ForegroundColor Cyan
foreach ($p in $people) {

    $prenom = $p.Prenom.Trim()
    $nom    = $p.Nom.Trim()
    if (-not $prenom -or -not $nom) { continue }

    $dept   = $p.Departement.Trim()
    $service= $p.Service.Trim()

    # OU du département (créée à la volée)
    $deptOuDN = New-OuIfMissing -Name $dept -ParentDN $usersOuDN

    # Groupe de sécurité global par département : GG_<Dept sans accents/espaces>
    if (-not $deptGroups.ContainsKey($dept)) {
        $grpName = "GG_" + (ConvertTo-Slug $dept)
        if (-not (Get-ADGroup -Filter "Name -eq '$grpName'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $grpName -GroupScope Global -GroupCategory Security `
                        -Path $groupsOuDN -Description "Collaborateurs du département $dept"
        }
        $deptGroups[$dept] = (Get-ADGroup -Identity $grpName).DistinguishedName
    }

    # sAMAccountName = 1ère lettre prénom + nom, tronqué à 20, collisions gérées
    $base = (ConvertTo-Slug ($prenom.Substring(0,1) + $nom))
    if ($base.Length -gt 20) { $base = $base.Substring(0,20) }
    $sam = $base; $i = 1
    while ($usedSam.ContainsKey($sam) -or
           (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue)) {
        $suffix = [string]$i
        $sam = $base.Substring(0, [Math]::Min($base.Length, 20 - $suffix.Length)) + $suffix
        $i++
    }
    $usedSam[$sam] = $true

    $upn         = (ConvertTo-Slug $prenom) + "." + (ConvertTo-Slug $nom) + "@" + $UpnSuffix
    $displayName = "$prenom $nom"

    # Le compte existe déjà ? -> on ne recrée pas
    $existing = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
    if ($existing) {
        $userByName["$prenom|$nom"] = $existing.DistinguishedName
        $skipped++
        continue
    }

    # Attributs (on ignore les champs vides)
    $attrs = @{
        Name              = $displayName
        GivenName         = $prenom
        Surname           = $nom
        DisplayName       = $displayName
        SamAccountName    = $sam
        UserPrincipalName = $upn
        Path              = $deptOuDN
        AccountPassword   = $SecurePwd
        Enabled           = $true
        ChangePasswordAtLogon = $true
        Company           = $p.Societe.Trim()
        Department        = $dept
        Title             = $p.fonction.Trim()
        Office            = $p.Site.Trim()
    }
    if ($service)                 { $attrs.Description  = $service }
    if ($p.'Telephone fixe')      { $attrs.OfficePhone  = $p.'Telephone fixe'.Trim() }
    if ($p.'Telephone portable')  { $attrs.MobilePhone  = $p.'Telephone portable'.Trim() }

    New-ADUser @attrs
    $dn = (Get-ADUser -Identity $sam).DistinguishedName
    $userByName["$prenom|$nom"] = $dn

    # Ajout au groupe du département
    Add-ADGroupMember -Identity $deptGroups[$dept] -Members $dn

    $report += [pscustomobject]@{
        Prenom = $prenom; Nom = $nom; Login = $sam; UPN = $upn
        Departement = $dept; Service = $service; Fonction = $p.fonction.Trim()
        OU = $deptOuDN
    }
    $created++
    Write-Host "  + $displayName  ->  $sam" -ForegroundColor Green
}

# --- 4. Passe 2 : liaison des managers -----------------------------
Write-Host "`n[4] Liaison des managers..." -ForegroundColor Cyan
$mgrLinked = 0
foreach ($p in $people) {
    $key = "$($p.Prenom.Trim())|$($p.Nom.Trim())"
    $mkey= "$($p.'Manager-Prenom'.Trim())|$($p.'Manager-Nom'.Trim())"
    if ($userByName.ContainsKey($key) -and $userByName.ContainsKey($mkey) -and $key -ne $mkey) {
        Set-ADUser -Identity $userByName[$key] -Manager $userByName[$mkey]
        $mgrLinked++
    }
}
Write-Host "    $mgrLinked managers liés."

# --- 5. Rapport ----------------------------------------------------
$report | Export-Csv -Path $ReportPath -Delimiter $Delimiter -Encoding UTF8 -NoTypeInformation
Write-Host "`n==================== BILAN ====================" -ForegroundColor Yellow
Write-Host "  Comptes créés   : $created"
Write-Host "  Comptes ignorés : $skipped (déjà existants)"
Write-Host "  Managers liés   : $mgrLinked"
Write-Host "  Rapport         : $ReportPath"
Write-Host "===============================================`n" -ForegroundColor Yellow
