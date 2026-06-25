<#
====================================================================
 New-EcoTechADUsers.ps1  (v2 - robuste encodage / séparateur / null)
 Création en masse des comptes AD EcoTechSolutions depuis la liste RH.
 --------------------------------------------------------------------
 - Détecte automatiquement le séparateur du CSV (; ou ,)
 - Vérifie la présence des colonnes attendues
 - Accès null-safe à chaque champ (plus de crash .Trim() sur null)
 - Crée l'arborescence d'OU : OU=EcoTech > Utilisateurs > <Département>
 - sAMAccountName = 1ère lettre prénom + nom (gère les collisions)
 - UPN prenom.nom@<suffixe> ; idempotent ; rapport CSV ; managers en 2e passe
 A exécuter SUR le contrôleur de domaine, PowerShell en Administrateur.
====================================================================
#>

# ----------------------- PARAMÈTRES À ADAPTER -----------------------
$CsvPath     = ".\collaborateurs.csv"
$DomainDN    = "DC=ecotechsolutions,DC=lan"
$UpnSuffix   = "ecotech.lan"
$RootOuName  = "EcoTech"
$DefaultPwd  = "Azerty123!*"
$ReportPath  = ".\rapport-comptes.csv"
# --------------------------------------------------------------------

Import-Module ActiveDirectory -ErrorAction Stop
$ErrorActionPreference = 'Stop'
$SecurePwd = ConvertTo-SecureString $DefaultPwd -AsPlainText -Force

# --- Fonctions utilitaires -----------------------------------------

# Lit un champ de façon sûre : null/absent -> "" ; sinon valeur "trimée"
function Get-F($obj, [string]$name) {
    $prop = $obj.PSObject.Properties[$name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return "" }
    return ([string]$prop.Value).Trim()
}

# Retire accents et caractères spéciaux pour les logins
function ConvertTo-Slug([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    $norm = $text.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($c in $norm.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne
            [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($c) }
    }
    return ($sb.ToString() -replace '[^a-zA-Z0-9]', '').ToLower()
}

# Crée une OU si absente (protégée contre suppression accidentelle)
function New-OuIfMissing([string]$Name, [string]$ParentDN) {
    $dn = "OU=$Name,$ParentDN"
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$Name'" -SearchBase $ParentDN -SearchScope OneLevel -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $Name -Path $ParentDN -ProtectedFromAccidentalDeletion $true
        Write-Host "  OU creee : $dn" -ForegroundColor DarkGray
    }
    return $dn
}

# --- 0. Lecture + contrôle du CSV ----------------------------------
Write-Host "`n[0] Lecture du CSV : $CsvPath" -ForegroundColor Cyan
if (-not (Test-Path $CsvPath)) { throw "Fichier introuvable : $CsvPath" }

# Détection automatique du séparateur depuis la 1ère ligne
$firstLine = Get-Content -Path $CsvPath -TotalCount 1
$nSemi  = ($firstLine.ToCharArray() | Where-Object { $_ -eq ';' }).Count
$nComma = ($firstLine.ToCharArray() | Where-Object { $_ -eq ',' }).Count
$Delimiter = if ($nSemi -ge $nComma) { ';' } else { ',' }
Write-Host "    Separateur detecte : '$Delimiter'"

$people = Import-Csv -Path $CsvPath -Delimiter $Delimiter -Encoding UTF8
if (-not $people -or $people.Count -eq 0) { throw "CSV vide ou illisible." }

# Contrôle des colonnes attendues
$cols = $people[0].PSObject.Properties.Name
foreach ($needed in 'Prenom','Nom','Departement') {
    if ($cols -notcontains $needed) {
        throw "Colonne '$needed' introuvable. Colonnes lues : $($cols -join ' | ')"
    }
}
Write-Host "    $($people.Count) collaborateurs a traiter." -ForegroundColor Green

# --- 1. Arborescence d'OU de base ----------------------------------
Write-Host "`n[1] Verification de l'arborescence d'OU..." -ForegroundColor Cyan
$rootOuDN   = New-OuIfMissing -Name $RootOuName    -ParentDN $DomainDN
$usersOuDN  = New-OuIfMissing -Name "Utilisateurs" -ParentDN $rootOuDN
$groupsOuDN = New-OuIfMissing -Name "Groupes"      -ParentDN $rootOuDN
$null       = New-OuIfMissing -Name "Ordinateurs"  -ParentDN $rootOuDN
$null       = New-OuIfMissing -Name "Serveurs"     -ParentDN $rootOuDN

# Tables de suivi
$usedSam    = @{}
$userByName = @{}
$deptGroups = @{}
$report     = @()
$created = 0; $skipped = 0; $ignored = 0

# --- 2. Passe 1 : OU département, groupes, utilisateurs ------------
Write-Host "`n[2] Creation des comptes..." -ForegroundColor Cyan
foreach ($p in $people) {

    $prenom = Get-F $p 'Prenom'
    $nom    = Get-F $p 'Nom'
    if (-not $prenom -or -not $nom) { $ignored++; continue }   # ligne vide -> ignorée

    $dept    = Get-F $p 'Departement'; if (-not $dept) { $dept = "Sans departement" }
    $service = Get-F $p 'Service'

    $deptOuDN = New-OuIfMissing -Name $dept -ParentDN $usersOuDN

    # Groupe de sécurité global par département
    if (-not $deptGroups.ContainsKey($dept)) {
        $grpName = "GG_" + (ConvertTo-Slug $dept)
        if (-not (Get-ADGroup -Filter "Name -eq '$grpName'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $grpName -GroupScope Global -GroupCategory Security `
                        -Path $groupsOuDN -Description "Collaborateurs du departement $dept"
        }
        $deptGroups[$dept] = (Get-ADGroup -Identity $grpName).DistinguishedName
    }

    # sAMAccountName = 1ère lettre prénom + nom, max 20, collisions gérées
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

    # Déjà présent ? on ne recrée pas, mais on garde le DN pour les managers
    $existing = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
    if ($existing) { $userByName["$prenom|$nom"] = $existing.DistinguishedName; $skipped++; continue }

    $attrs = @{
        Name                  = $displayName
        GivenName             = $prenom
        Surname               = $nom
        DisplayName           = $displayName
        SamAccountName        = $sam
        UserPrincipalName     = $upn
        Path                  = $deptOuDN
        AccountPassword       = $SecurePwd
        Enabled               = $true
        ChangePasswordAtLogon = $true
        Department            = $dept
    }
    $societe = Get-F $p 'Societe';            if ($societe)  { $attrs.Company     = $societe }
    $fonction= Get-F $p 'fonction';           if ($fonction) { $attrs.Title       = $fonction }
    $site    = Get-F $p 'Site';               if ($site)     { $attrs.Office       = $site }
    if ($service)                             { $attrs.Description = $service }
    $telFixe = Get-F $p 'Telephone fixe';     if ($telFixe)  { $attrs.OfficePhone  = $telFixe }
    $telPort = Get-F $p 'Telephone portable'; if ($telPort)  { $attrs.MobilePhone  = $telPort }

    New-ADUser @attrs
    $dn = (Get-ADUser -Identity $sam).DistinguishedName
    $userByName["$prenom|$nom"] = $dn
    Add-ADGroupMember -Identity $deptGroups[$dept] -Members $dn

    $report += [pscustomobject]@{
        Prenom=$prenom; Nom=$nom; Login=$sam; UPN=$upn
        Departement=$dept; Service=$service; Fonction=$fonction; OU=$deptOuDN
    }
    $created++
    Write-Host "  + $displayName  ->  $sam" -ForegroundColor Green
}

# --- 3. Passe 2 : liaison des managers -----------------------------
Write-Host "`n[3] Liaison des managers..." -ForegroundColor Cyan
$mgrLinked = 0
foreach ($p in $people) {
    $key  = "$(Get-F $p 'Prenom')|$(Get-F $p 'Nom')"
    $mkey = "$(Get-F $p 'Manager-Prenom')|$(Get-F $p 'Manager-Nom')"
    if ($userByName.ContainsKey($key) -and $userByName.ContainsKey($mkey) -and $key -ne $mkey) {
        Set-ADUser -Identity $userByName[$key] -Manager $userByName[$mkey]
        $mgrLinked++
    }
}
Write-Host "    $mgrLinked managers lies."

# --- 4. Rapport ----------------------------------------------------
$report | Export-Csv -Path $ReportPath -Delimiter $Delimiter -Encoding UTF8 -NoTypeInformation
Write-Host "`n==================== BILAN ====================" -ForegroundColor Yellow
Write-Host "  Comptes crees   : $created"
Write-Host "  Comptes ignores : $skipped (deja existants)"
Write-Host "  Lignes vides    : $ignored"
Write-Host "  Managers lies   : $mgrLinked"
Write-Host "  Rapport         : $ReportPath"
Write-Host "===============================================`n" -ForegroundColor Yellow
