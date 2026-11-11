@{
    Preconditions = @('Setup', 'Ready')
    Groups = @(
        @{ Name = 'presentation'; Modules = @('Navigation', 'Settings', 'Appearance', 'Responsive') }
        @{ Name = 'scan-flows'; Modules = @('Refresh', 'PeopleRooms') }
        @{ Name = 'scan-presentation'; Modules = @('Progress') }
        @{ Name = 'preferences-scheduling'; Modules = @('Persistence', 'Scheduled') }
    )
}
