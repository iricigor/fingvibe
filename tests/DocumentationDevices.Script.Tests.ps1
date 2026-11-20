$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DocumentationDevices.Fixture.ps1')
foreach ($name in @('DocumentationDevices.Fixture.ps1', 'DocumentationDevices.Ui.Tests.ps1')) {
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name), [ref]$null, [ref]$errors)
    if ($errors) { throw ($errors.Message -join '; ') }
}
$bin = Join-Path $PSScriptRoot 'FingVibe.Core.Tests\bin\Release\net8.0'
$null = [Runtime.InteropServices.NativeLibrary]::Load((Join-Path $bin 'runtimes\win-x64\native\e_sqlite3.dll'))
foreach ($name in @('FingVibe.Core.dll', 'SQLitePCLRaw.core.dll', 'SQLitePCLRaw.provider.e_sqlite3.dll',
    'SQLitePCLRaw.batteries_v2.dll', 'Microsoft.Data.Sqlite.dll')) {
    $null = [Reflection.Assembly]::LoadFrom((Join-Path $bin $name))
}
[SQLitePCL.Batteries_V2]::Init()
$directory = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-doc-devices-$([Guid]::NewGuid().ToString('N'))"
try {
    $null = New-Item -ItemType Directory -Path $directory
    $fixture = New-DocumentationDevicesFixture $directory
    Add-DocumentationDevicesLink $fixture.Inventory
    $token = [Threading.CancellationToken]::None
    $store = [FingVibe.Core.Storage.DeviceInventoryStore]::new([IO.Path]::ChangeExtension($fixture.Inventory, '.sqlite'))
    $saved = $store.LoadMetadataAsync($token).GetAwaiter().GetResult()
    if ($saved.Devices.Count -ne 10 -or $saved.LinkedDevices.Count -ne 1 -or $saved.VirtualDevices.Count -ne 0) {
        throw 'The documentation fixture must represent nine devices, including one explicitly linked PC.'
    }
    $pc = $saved.LinkedDevices[0]
    if ($pc.Name -ne 'Workstation' -or $pc.Members.Count -ne 2 -or
        $pc.Identification.Type -ne 'Computer' -or $pc.Identification.OperatingSystem -ne 'Windows' -or
        (@($pc.Members.Mac | Sort-Object) -join ',') -ne '001122550002,001122550003') {
        throw 'The PC must link its Ethernet/Wi-Fi MACs and retain Windows Computer identification.'
    }
    if (@($saved.Devices.Values.LatestObservation.Classification.Type | Sort-Object -Unique).Count -lt 8) {
        throw 'The documentation fixture must include the agreed varied device types.'
    }
    $snapshot = [FingVibe.Core.Storage.ScanSnapshotStore]::new($fixture.Snapshot).LoadAsync($token).GetAwaiter().GetResult()
    if ($snapshot.Results.Count -ne 10) { throw 'The snapshot must retain both linked NICs and all other responders.' }
    foreach ($name in @('Kitchen speaker', 'Hue bridge')) {
        $result = @($snapshot.Results | Where-Object DeviceName -eq $name)
        if ($result.Count -ne 1 -or $result[0].RoundtripTimeMilliseconds -ne $null -or
            $result[0].ServiceAdvertisements.Count -lt 1 -or $result[0].Status -ne 'Alive') {
            throw "'$name' must be a service-discovery responder without invented ping latency."
        }
        if (-not [Net.IPAddress]::IsLoopback($result[0].Address)) { throw 'Documentation responders must use loopback addresses.' }
    }
    $bridge = @($snapshot.Results | Where-Object DeviceName -eq 'Hue bridge')[0]
    if ($bridge.OpenPorts.Count -ne 0 -or $bridge.ServiceAdvertisements[0].Verification -ne 'NoResponse') {
        throw 'A nonresponding advertised TCP port must not appear as verified open.'
    }
    if ($saved.PeopleRooms.Rooms.Count -ne 3 -or
        $pc.Assignment.RoomId -ne [Guid]'10000000-0000-0000-0000-000000000002' -or
        $saved.GetAssignment('001122550004') -ne $null -or $saved.GetAssignment('001122550005') -ne $null) {
        throw 'The Room map fixture must have populated rooms, one shared linked-PC assignment and unassigned equipment.'
    }
    $mapDirectory = Join-Path $directory 'room-map'
    $null = New-Item -ItemType Directory -Path $mapDirectory
    $mapFixture = New-DocumentationDevicesFixture -Directory $mapDirectory -Subnet '127.0.0.1/32'
    Add-DocumentationDevicesLink $mapFixture.Inventory
    $mapStore = [FingVibe.Core.Storage.DeviceInventoryStore]::new([IO.Path]::ChangeExtension($mapFixture.Inventory, '.sqlite'))
    $mapData = $mapStore.LoadMetadataAsync($token).GetAwaiter().GetResult()
    $network = [FingVibe.Core.Models.LanNetwork]::new('UI review loopback', [Net.IPAddress]::Loopback,
        [Net.IPAddress]::Loopback, 32, $false)
    $projection = [FingVibe.Core.Models.RoomMapProjection]::Create($mapData, $network, 'ui-review-network')
    if ($projection.Devices.Count -ne 9 -or $projection.UnassignedDevices.Count -ne 2 -or
        @($projection.Rooms | Where-Object { -not $_.IsPlaceholder }).Count -ne 3 -or
        @($projection.Devices | Where-Object Name -eq 'Workstation').Count -ne 1) {
        throw 'The actual Room map projection must show three populated rooms and nine devices, counting the linked PC once.'
    }
    Write-Host 'Documentation Devices fixture/link/service-discovery checks passed without desktop automation.'
}
finally { Remove-Item -LiteralPath $directory -Recurse -Force }
