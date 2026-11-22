@{
    Preconditions = @('Setup', 'Ready')
    Groups = @(
        @{ Name = 'presentation'; Modules = @('Navigation', 'Settings', 'Appearance', 'Responsive') }
        @{ Name = 'scan-flows'; Modules = @('Refresh', 'PeopleRooms') }
        @{ Name = 'scan-presentation'; Modules = @('Progress', 'FixedHeaders') }
        @{ Name = 'preferences-scheduling'; Modules = @('SettingsDisclosure', 'Persistence', 'Scheduled') }
    )
}
