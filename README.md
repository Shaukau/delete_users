Import-Module ActiveDirectory

$CsvPath = "C:\Scripts\departs_collaborateurs.csv"
$ArchiveOU = "OU=BU_Anciens_Collaborateurs,DC=BillU,DC=lan"
$LogPath = "C:\Scripts\logs_departs_collaborateurs.txt"

$Users = Import-Csv -Path $CsvPath -Delimiter ";"

foreach ($User in $Users) {

    $Sam = $User.SamAccountName
    $DateDepart = $User.DateDepart
    $Ticket = $User.Ticket

    Write-Host "Traitement du compte : $Sam" -ForegroundColor Cyan

    try {
        $ADUser = Get-ADUser -Identity $Sam -Properties MemberOf, DistinguishedName, Description

        # Désactivation du compte
        Disable-ADAccount -Identity $Sam

        # Retrait des groupes sauf Domain Users
        foreach ($GroupDN in $ADUser.MemberOf) {
            $Group = Get-ADGroup -Identity $GroupDN

            if ($Group.Name -ne "Domain Users") {
                Remove-ADGroupMember -Identity $Group -Members $Sam -Confirm:$false
            }
        }

        # Ajout d'une trace dans la description
        Set-ADUser -Identity $Sam `
            -Description "Compte désactivé suite au départ du collaborateur - Date : $DateDepart - Ticket : $Ticket"

        # Déplacement dans l'OU d'archive
        Move-ADObject -Identity $ADUser.DistinguishedName -TargetPath $ArchiveOU

        Add-Content $LogPath "[$(Get-Date)] OK : $Sam désactivé, groupes retirés, déplacé dans $ArchiveOU"

        Write-Host "Compte $Sam traité avec succès" -ForegroundColor Green
    }
    catch {
        Add-Content $LogPath "[$(Get-Date)] ERREUR : $Sam - $($_.Exception.Message)"
        Write-Host "Erreur avec le compte $Sam" -ForegroundColor Red
    }
}
