######################################################################################################
#                                                                                                    #
#   BillU - Creation automatique des utilisateurs AD depuis ListeRHCollaborateurs.csv               #
#   (filtre Societe = BillU | doublons geres par date de naissance DDMMYYYY)                        #
#                                                                                                    #
######################################################################################################

$FilePath = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Definition)

### Parametre(s) a modifier
$File = "$FilePath\s01-a02-BillU-ListeRHCollaborateurs.csv"

### Table de correspondance Departement CSV --> OU Active Directory
$OUMap = @{
    "Developpement logiciel"               = "Developpement"
    "Departement Juridique"                = "Juridique"
    "Finance et Comptabilite"              = "Comptabilite"
    "Service Commercial"                   = "Commercial"
    "Communication et Relations publiques" = "Communication"
    "Direction"                            = "Direction/Qualite/Recrutement"
    "Service recrutement"                  = "Direction/Qualite/Recrutement"
    "QHSE"                                 = "Direction/Qualite/Recrutement"
    "DSI"                                  = "DSI"
}

### Fonction de nettoyage des accents
Function Remove-Accents {
    Param([string]$Text)
    $Normalized = $Text.Normalize([System.Text.NormalizationForm]::FormD)
    $Clean = ""
    Foreach ($Char in $Normalized.ToCharArray()) {
        $Category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($Char)
        If ($Category -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            $Clean += $Char
        }
    }
    $Clean = $Clean -replace "[-' ]", ""
    Return $Clean
}

### Main program
Clear-Host

If (-not(Get-Module -Name activedirectory)) {
    Import-Module activedirectory
}

$Users      = Import-Csv -Path $File -Delimiter "," -Encoding UTF8
$ADUsers    = Get-ADUser -Filter * -Properties SamAccountName
$DomainFQDN = (Get-ADDomain).Forest
$Count      = 1
$Skipped    = 0
$Created    = 0
$Exists     = 0

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   BillU - Creation des comptes utilisateurs Active Directory" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Foreach ($User in $Users) {

    # Filtrage : on ne traite que les employes BillU
    If ($User.Societe -ne "BillU") {
        Write-Host "[ IGNORE  ] $($User.Prenom) $($User.Nom) (Societe : $($User.Societe))" -ForegroundColor DarkGray
        $Skipped++
        $Count++
        Continue
    }

    Write-Progress -Activity "Creation des utilisateurs BillU dans l'AD" `
                   -Status "Traitement de $($User.Prenom) $($User.Nom)" `
                   -PercentComplete ($Count / $Users.Length * 100)

    # Construction du SamAccountName de base
    $PrenomClean = Remove-Accents -Text $User.Prenom
    $NomClean    = Remove-Accents -Text $User.Nom
    $SamBase     = ($PrenomClean.Substring(0,1).ToLower() + $NomClean.ToLower())
    $SamBase     = $SamBase.Substring(0, [Math]::Min(12, $SamBase.Length))

    # Gestion des doublons : apatel -> apatel21041996 (DDMMYYYY)
    $SamAccountName = $SamBase

    $SAMExists = ($ADUsers | Where-Object { $_.SamAccountName -eq $SamAccountName }) -ne $null
    $UPNExists = (Get-ADUser -LDAPFilter "(userPrincipalName=$SamAccountName@$DomainFQDN)" -ErrorAction SilentlyContinue) -ne $null

    If ($SAMExists -or $UPNExists) {
        # Formatage de la date de naissance en DDMMYYYY
        If ($User."Date de naissance" -ne "-" -and $User."Date de naissance" -ne "") {
            Try {
                $DOB       = [datetime]::ParseExact($User."Date de naissance", "dd/MM/yyyy", $null)
                $DOBSuffix = $DOB.ToString("ddMMyyyy")
            } Catch {
                $DOBSuffix = "00000000"
            }
        } Else {
            $DOBSuffix = "00000000"
        }
        $SamAccountName = $SamBase + $DOBSuffix
        Write-Host "[ DOUBLON ] Login de base deja pris -> nouveau login : $SamAccountName" -ForegroundColor Magenta
    }

    $Name              = "$($User.Nom) $($User.Prenom)"
    $DisplayName       = "$($User.Nom) $($User.Prenom)"
    $UserPrincipalName = $SamAccountName + "@" + $DomainFQDN
    $GivenName         = $User.Prenom
    $Surname           = $User.Nom
    $EmailAddress      = $UserPrincipalName
    $Department        = $User.Departement
    $Title             = $User.fonction
    $Company           = "BillU"

    # Telephone fixe
    If ($User."Telephone fixe" -ne "-" -and $User."Telephone fixe" -ne "") {
        $OfficePhone = $User."Telephone fixe"
    } Else {
        $OfficePhone = $null
    }

    # Telephone mobile
    If ($User."Telephone portable" -ne "-" -and $User."Telephone portable" -ne "") {
        $MobilePhone = $User."Telephone portable"
    } Else {
        $MobilePhone = $null
    }

    # Resolution de l'OU cible par recherche partielle
    $OUName = $null
    If     ($User.Departement -like "*logiciel*" -or $User.Departement -like "*veloppement*") { $OUName = "Developpement" }
    ElseIf ($User.Departement -like "*Juridique*")                                            { $OUName = "Juridique" }
    ElseIf ($User.Departement -like "*Comptabilit*" -or $User.Departement -like "*Finance*")  { $OUName = "Comptabilite" }
    ElseIf ($User.Departement -like "*Commercial*")                                           { $OUName = "Commercial" }
    ElseIf ($User.Departement -like "*Communication*")                                        { $OUName = "Communication" }
    ElseIf ($User.Departement -like "*Direction*" -or $User.Departement -like "*recrutement*" -or $User.Departement -like "*QHSE*") { $OUName = "Direction/Qualite/Recrutement" }
    ElseIf ($User.Departement -like "*DSI*")                                                  { $OUName = "DSI" }

    If (-not $OUName) {
        Write-Host "[ ATTENTION ] Departement inconnu '$($User.Departement)' pour $($User.Prenom) $($User.Nom) - ignore." -ForegroundColor Yellow
        $Skipped++
        $Count++
        Continue
    }

    $Path = "ou=$OUName,ou=BU-Users,dc=BillU,dc=lan"

    # Creation ou detection doublon
    If (($ADUsers | Where-Object { $_.SamAccountName -eq $SamAccountName }) -eq $null) {

        Try {
            $Params = @{
                Name                  = $Name
                DisplayName           = $DisplayName
                SamAccountName        = $SamAccountName
                UserPrincipalName     = $UserPrincipalName
                GivenName             = $GivenName
                Surname               = $Surname
                EmailAddress          = $EmailAddress
                Path                  = $Path
                AccountPassword       = (ConvertTo-SecureString -AsPlainText "Azerty123!*" -Force)
                Enabled               = $True
                ChangePasswordAtLogon = $True
                OtherAttributes       = @{
                    Company    = $Company
                    Department = $Department
                    Title      = $Title
                }
            }

            If ($OfficePhone) { $Params["OfficePhone"] = $OfficePhone }
            If ($MobilePhone) { $Params["MobilePhone"] = $MobilePhone }

            New-ADUser @Params

            Set-ADObject -Identity (Get-ADUser $SamAccountName) -ProtectedFromAccidentalDeletion $False

            Write-Host "[ CREE    ] $SamAccountName - $($User.Prenom) $($User.Nom) -> OU: $OUName" -ForegroundColor Green
            $Created++
        }
        Catch {
            Write-Host "[ ERREUR  ] Impossible de creer $SamAccountName : $_" -ForegroundColor Red
        }
    }
    Else {
        Write-Host "[ EXISTANT] $SamAccountName ($($User.Prenom) $($User.Nom)) existe deja." -ForegroundColor Black -BackgroundColor Yellow
        $Exists++
    }

    $Count++
    Start-Sleep -Milliseconds 100
}

# Resume final
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   Resume de l'execution" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Comptes crees     : $Created" -ForegroundColor Green
Write-Host "  Comptes existants : $Exists"  -ForegroundColor Yellow
Write-Host "  Lignes ignorees   : $Skipped" -ForegroundColor DarkGray
Write-Host "  Total traite      : $($Count - 1)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
