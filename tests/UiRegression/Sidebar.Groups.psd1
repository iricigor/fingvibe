@{
    Preconditions = @('Setup', 'Ready')
    Groups = @(
        @{ Name = 'presentation'; Modules = @('Navigation', 'Settings', 'Appearance', 'Responsive') }
        @{ Name = 'scan-flows'; Modules = @('Refresh', 'Progress', 'PeopleRooms') }
        @{ Name = 'preferences-scheduling'; Modules = @('Persistence', 'Scheduled') }
    )
}
