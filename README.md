Import-Module ActiveDirectory

$CsvPath = "C:\Scripts\feminisation_postes.csv"
$LogPath = "C:\Scripts\Logs\logs_feminisation_postes.txt"

# $true = test sans modifier l'AD
# $false = modification reelle
$ModeTest = $true

# Caracteres accentues en Unicode pour eviter les problemes d'encodage
$eAigu = [char]0x00E9
$eGrave = [char]0x00E8
$oCirc = [char]0x00F4

function Remove-Accents {
    param ([string]$Text)

    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object System.Text.StringBuilder

    foreach ($c in $normalized.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($c)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($c)
        }
    }

    return $builder.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function Convert-ToFeminineTitle {
    param ([string]$Title)

    $CleanTitle = $Title.Trim()
    $NormalizedTitle = (Remove-Accents $CleanTitle).ToLower()

    # Si le titre est deja feminin, on ne rajoute rien
    $AlreadyFeminine = @(
        "directrice",
        "technicienne",
        "administratrice",
        "developpeuse",
        "commerciale",
        "assistante",
        "controleuse",
        "conseillere",
        "chargee",
        "agente",
        "acheteuse",
        "auditrice",
        "redactrice",
        "designeuse"
    )

    foreach ($Fem in $AlreadyFeminine) {
        if ($NormalizedTitle.StartsWith($Fem)) {
            return $CleanTitle
        }
    }

    $Rules = @(
        @{ Prefix = "Directeur"; Normalized = "directeur"; Replacement = "Directrice" },
        @{ Prefix = "Technicien"; Normalized = "technicien"; Replacement = "Technicienne" },
        @{ Prefix = "Administrateur"; Normalized = "administrateur"; Replacement = "Administratrice" },
        @{ Prefix = "D${eAigu}veloppeur"; Normalized = "developpeur"; Replacement = "D${eAigu}veloppeuse" },
        @{ Prefix = "Developpeur"; Normalized = "developpeur"; Replacement = "D${eAigu}veloppeuse" },
        @{ Prefix = "Commercial"; Normalized = "commercial"; Replacement = "Commerciale" },
        @{ Prefix = "Assistant"; Normalized = "assistant"; Replacement = "Assistante" },
        @{ Prefix = "Contr${oCirc}leur"; Normalized = "controleur"; Replacement = "Contr${oCirc}leuse" },
        @{ Prefix = "Controleur"; Normalized = "controleur"; Replacement = "Contr${oCirc}leuse" },
        @{ Prefix = "Conseiller"; Normalized = "conseiller"; Replacement = "Conseill${eGrave}re" },
        @{ Prefix = "Charg${eAigu}"; Normalized = "charge"; Replacement = "Charg${eAigu}e" },
        @{ Prefix = "Charge"; Normalized = "charge"; Replacement = "Charg${eAigu}e" },
        @{ Prefix = "Agent RH"; Normalized = "agent rh"; Replacement = "Agente RH" },
        @{ Prefix = "Agent"; Normalized = "agent"; Replacement = "Agente" },
        @{ Prefix = "Acheteur"; Normalized = "acheteur"; Replacement = "Acheteuse" },
        @{ Prefix = "Auditeur"; Normalized = "auditeur"; Replacement = "Auditrice" },
        @{ Prefix = "R${eAigu}dacteur"; Normalized = "redacteur"; Replacement = "R${eAigu}dactrice" },
        @{ Prefix = "Redacteur"; Normalized = "redacteur"; Replacement = "R${eAigu}dactrice" },
        @{ Prefix = "Designer graphique"; Normalized = "designer graphique"; Replacement = "Designeuse graphique" }
    )

    foreach ($Rule in $Rules) {
        if ($NormalizedTitle.StartsWith($Rule.Normalized)) {
            $Rest = $CleanTitle.Substring($Rule.Prefix.Length)
            return $Rule.Replacement + $Rest
        }
    }

    return $CleanTitle
}

$Users = Import-Csv -Path $CsvPath -Delimiter ";" -Encoding UTF8

foreach ($User in $Users) {

    $Sam = $User.SamAccountName
    $Marker = $User.PosteFeminise

    if ([string]::IsNullOrWhiteSpace($Marker)) {
        Write-Host "Ignore : $Sam non concerne" -ForegroundColor DarkGray
        continue
    }

    try {
        $ADUser = Get-ADUser -Identity $Sam -Properties Title,Department

        # IMPORTANT :
        # On part du Title du CSV, pas du Title actuel dans l'AD.
        # Cela evite les Assistanteeeee si le script est relance plusieurs fois.
        $TitreSource = $User.Title
        $AncienPosteAD = $ADUser.Title
        $Departement = $ADUser.Department
        $NouveauPoste = Convert-ToFeminineTitle -Title $TitreSource

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
    catch {
        Add-Content -Path $LogPath -Encoding UTF8 -Value "[$(Get-Date)] ERREUR : $Sam - $($_.Exception.Message)"
        Write-Host "Erreur avec le compte $Sam : $($_.Exception.Message)" -ForegroundColor Red
    }
}
