Import-Module ActiveDirectory

$CsvPath = "C:\Scripts\feminisation_postes.csv"
$LogPath = "C:\Scripts\logs_feminisation_postes.txt"

# $true = test sans modifier l'AD / $false = modification réelle
$ModeTest = $true

function Convert-ToFeminineTitle {
    param (
        [string]$Title
    )
    
    $NewTitle = $Title.Trim()
    
    # Utiliser -iregex pour ignorer la casse
    $NewTitle = $NewTitle -ireplace "^Directeur\b", "Directrice"
    $NewTitle = $NewTitle -ireplace "^Technicien\b", "Technicienne"
    $NewTitle = $NewTitle -ireplace "^Administrateur\b", "Administratrice"
    $NewTitle = $NewTitle -ireplace "^Développeur\b", "Développeuse"
    $NewTitle = $NewTitle -ireplace "^Commercial\b", "Commerciale"
    $NewTitle = $NewTitle -ireplace "^Assistant\b", "Assistante"
    $NewTitle = $NewTitle -ireplace "^Contrôleur\b", "Contrôleuse"
    $NewTitle = $NewTitle -ireplace "^Conseiller\b", "Conseillère"
    $NewTitle = $NewTitle -ireplace "^Chargé\b", "Chargée"
    $NewTitle = $NewTitle -ireplace "^Agent RH\b", "Agente RH"
    
    return $NewTitle
}

$Users = Import-Csv -Path $CsvPath -Delimiter ";"

foreach ($User in $Users) {
    $Sam = $User.SamAccountName
    $Marker = $User.PosteFeminise
    
    if ([string]::IsNullOrWhiteSpace($Marker)) {
        Write-Host "Ignore : $Sam non concerne" -ForegroundColor DarkGray
        continue
    }
    
    try {
        $ADUser = Get-ADUser -Identity $Sam -Properties Title, Department
        
        $AncienPoste = $ADUser.Title
        $Departement = $ADUser.Department
        $NouveauPoste = Convert-ToFeminineTitle -Title $AncienPoste
        
        Write-Host "Utilisateur : $Sam" -ForegroundColor Cyan
        Write-Host "Ancien Title : '$AncienPoste'"
        Write-Host "Nouveau Title : '$NouveauPoste'"
        Write-Host "Department conserve : $Departement"
        
        if ($AncienPoste -eq $NouveauPoste) {
            Write-Host "Aucune regle de feminisation appliquee pour ce poste" -ForegroundColor Yellow
            continue
        }
        
        if ($ModeTest -eq $false) {
            # Modification uniquement du champ Title
            Set-ADUser -Identity $Sam -Title $NouveauPoste
            
            Add-Content $LogPath "[$(Get-Date)] OK : $Sam - Title : $AncienPoste -> $NouveauPoste - Department conserve : $Departement"
            
            Write-Host "Modification appliquee uniquement sur le Title" -ForegroundColor Green
        }
        else {
            Write-Host "MODE TEST : aucune modification appliquee" -ForegroundColor Yellow
        }
    }
    catch {
        Add-Content $LogPath "[$(Get-Date)] ERREUR : $Sam - $($_.Exception.Message)"
        Write-Host "Erreur avec le compte $Sam : $($_.Exception.Message)" -ForegroundColor Red
    }
}
