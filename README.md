Import-Module ActiveDirectory

chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$CsvPath = "C:\Scripts\feminisation_postes.csv"
$LogPath = "C:\Scripts\Logs\logs_feminisation_postes.txt"

# $true = test sans modifier l'AD
# $false = modification reelle
$ModeTest = $false

New-Item -ItemType Directory -Path "C:\Scripts\Logs" -Force | Out-Null

$eAigu = [char]0x00E9
$eGrave = [char]0x00E8
$oCirc = [char]0x00F4

Write-Host "MODE ACTUEL DU SCRIPT : $ModeTest" -ForegroundColor Magenta

$Users = Import-Csv -Path $CsvPath -Delimiter ";" -Encoding UTF8

foreach ($User in $Users) {

    $Sam = $User.SamAccountName
    $Marker = $User.PosteFeminise

    if ([string]::IsNullOrWhiteSpace($Marker)) {
        Write-Host "Ignore : $Sam non concerne" -ForegroundColor DarkGray
        continue
    }

    $ADUser = Get-ADUser -Identity $Sam -Properties Title,Department

    $AncienPosteAD = $ADUser.Title
    $Departement = $ADUser.Department

    # On repart du titre propre du CSV pour eviter Assistanteeeee
    $TitreSource = $User.Title.Trim()
    $NouveauPoste = $TitreSource

    # Regles de feminisation uniquement sur le debut du titre
    $NouveauPoste = $NouveauPoste -ireplace "^Directeur", "Directrice"
    $NouveauPoste = $NouveauPoste -ireplace "^Technicien", "Technicienne"
    $NouveauPoste = $NouveauPoste -ireplace "^Administrateur", "Administratrice"
    $NouveauPoste = $NouveauPoste -ireplace "^D.veloppeur", "D${eAigu}veloppeuse"
    $NouveauPoste = $NouveauPoste -ireplace "^Developpeur", "D${eAigu}veloppeuse"
    $NouveauPoste = $NouveauPoste -ireplace "^Commercial", "Commerciale"
    $NouveauPoste = $NouveauPoste -ireplace "^Assistant", "Assistante"
    $NouveauPoste = $NouveauPoste -ireplace "^Contr.leur", "Contr${oCirc}leuse"
    $NouveauPoste = $NouveauPoste -ireplace "^Conseiller", "Conseill${eGrave}re"
    $NouveauPoste = $NouveauPoste -ireplace "^Charg.", "Charg${eAigu}e"
    $NouveauPoste = $NouveauPoste -ireplace "^Agent RH", "Agente RH"
    $NouveauPoste = $NouveauPoste -ireplace "^Agent", "Agente"
    $NouveauPoste = $NouveauPoste -ireplace "^Acheteur", "Acheteuse"
    $NouveauPoste = $NouveauPoste -ireplace "^Auditeur", "Auditrice"
    $NouveauPoste = $NouveauPoste -ireplace "^R.dacteur", "R${eAigu}dactrice"
    $NouveauPoste = $NouveauPoste -ireplace "^Designer graphique", "Designeuse graphique"

    Write-Host "Utilisateur : $Sam" -ForegroundColor Cyan
    Write-Host "Title actuel AD : $AncienPosteAD"
    Write-Host "Title source CSV : $TitreSource"
    Write-Host "Nouveau Title : $NouveauPoste"
    Write-Host "Department conserve : $Departement"

    if ($AncienPosteAD -eq $NouveauPoste) {
        Write-Host "Aucune modification necessaire" -ForegroundColor Yellow
        continue
    }

    if ($ModeTest -eq $false) {
        Set-ADUser -Identity $Sam -Title $NouveauPoste

        Add-Content -Path $LogPath -Encoding UTF8 -Value "[$(Get-Date)] OK : $Sam - Title : $AncienPosteAD -> $NouveauPoste - Department conserve : $Departement"

        Write-Host "Modification appliquee uniquement sur le Title" -ForegroundColor Green
    }
    else {
        Write-Host "MODE TEST : aucune modification appliquee" -ForegroundColor Yellow
    }
}
