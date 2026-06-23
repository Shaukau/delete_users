Import-Module ActiveDirectory

$CsvPath = "C:\Scripts\feminisation_postes.csv"
$LogPath = "C:\Scripts\logs_feminisation_postes.txt"

# Mode test : $true = affiche sans modifier
# Mode réel : $false = applique dans l'AD
$ModeTest = $true

function Convert-ToFeminineTitle {
    param (
        [string]$Title
    )

    $NewTitle = $Title

    $Rules = @{
        "Directeur" = "Directrice"
        "Directeur adjoint" = "Directrice adjointe"
        "Directeur commercial" = "Directrice commerciale"
        "Technicien" = "Technicienne"
        "Technicien informatique" = "Technicienne informatique"
        "Administrateur" = "Administratrice"
        "Administrateur système" = "Administratrice système"
        "Développeur" = "Développeuse"
        "Commercial" = "Commerciale"
        "Assistant" = "Assistante"
        "Assistant de direction" = "Assistante de direction"
        "Contrôleur de gestion" = "Contrôleuse de gestion"
        "Conseiller en fiscalité" = "Conseillère en fiscalité"
        "Chargé de communication" = "Chargée de communication"
        "Responsable communication" = "Responsable communication"
        "Responsable recrutement" = "Responsable recrutement"
        "Agent RH" = "Agente RH"
        "Juriste" = "Juriste"
        "Comptable" = "Comptable"
        "Community manager" = "Community manager"
    }

    foreach ($Rule in $Rules.GetEnumerator()) {
        if ($Title -eq $Rule.Key) {
            $NewTitle = $Rule.Value
        }
    }

    return $NewTitle
}

$Users = Import-Csv -Path $CsvPath -Delimiter ";"

foreach ($User in $Users) {

    $Sam = $User.SamAccountName
    $OldTitleFromCsv = $User.Title
    $Marker = $User.PosteFeminise

    if ([string]::IsNullOrWhiteSpace($Marker)) {
        Write-Host "Ignore : $Sam non concerne" -ForegroundColor DarkGray
        continue
    }

    try {
        $ADUser = Get-ADUser -Identity $Sam -Properties Title,Description

        $AncienPoste = $ADUser.Title
        $NouveauPoste = Convert-ToFeminineTitle -Title $AncienPoste

        Write-Host "Utilisateur : $Sam" -ForegroundColor Cyan
        Write-Host "Ancien poste : $AncienPoste"
        Write-Host "Nouveau poste : $NouveauPoste"

        if ($AncienPoste -eq $NouveauPoste) {
            Write-Host "Aucune règle de féminisation appliquée pour ce poste" -ForegroundColor Yellow
            continue
        }

        if ($ModeTest -eq $false) {
            Set-ADUser -Identity $Sam -Title $NouveauPoste

            Set-ADUser -Identity $Sam -Description "Poste feminise suite a la regle RH - Ancien poste : $AncienPoste - Nouveau poste : $NouveauPoste"

            Add-Content $LogPath "[$(Get-Date)] OK : $Sam - Ancien poste : $AncienPoste - Nouveau poste : $NouveauPoste"

            Write-Host "Modification appliquee pour $Sam" -ForegroundColor Green
        }
        else {
            Write-Host "MODE TEST : aucune modification appliquee" -ForegroundColor Yellow
        }
    }
    catch {
        Add-Content $LogPath "[$(Get-Date)] ERREUR : $Sam - $($_.Exception.Message)"
        Write-Host "Erreur avec le compte $Sam" -ForegroundColor Red
    }
}
