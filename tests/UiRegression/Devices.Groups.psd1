@{
    # Every group launches its own app from Setup and reaches the Devices page through Ready.
    Preconditions = @('Setup', 'Ready')
    # Modules within a group share state in their original relative order; groups never share state.
    Groups = @(
        @{ Name = 'presentation'; Modules = @('Overview', 'Layout', 'Appearance', 'Interaction') }
        @{ Name = 'filters-previews'; Modules = @('Filters', 'Previews') }
        @{ Name = 'columns-sorting'; Modules = @('Columns', 'Sorting') }
    )
}
