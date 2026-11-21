@{
    # Each existing check owns its fixture, app readiness and bounded shutdown.
    Preconditions = @()
    Groups = @(
        @{ Name = 'utilities'; Modules = @('Identity', 'NetworkHealth', 'Import', 'Updates', 'Backups') }
        @{ Name = 'device-data'; Modules = @('Services', 'Sql', 'SpeedTest') }
    )
}
