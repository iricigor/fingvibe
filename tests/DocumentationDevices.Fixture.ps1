function New-DocumentationDevicesFixture([string] $Directory, [DateTimeOffset] $Time = [DateTimeOffset]::UtcNow.AddMinutes(-1),
    [string] $Subnet = '127.0.0.0/24') {
    $seen = $Time.ToString('o')
    $devices = @{}
    $results = [Collections.Generic.List[object]]::new()
    function Add-DocumentationDevice([int] $Index, [string] $Name, [int] $Type, [int] $Os,
        $Latency, [object[]] $Ports = @(), [object[]] $Advertisements = @()) {
        $mac = '0011225500{0:X2}' -f $Index
        $address = "127.0.0.$Index"
        $classification = @{
            type = $Type; operatingSystem = $Os
            typeEvidence = 'Synthetic documentation fixture'; operatingSystemEvidence = 'Synthetic documentation fixture'
        }
        $devices[$mac] = @{
            mac = $mac; imported = @{}; observations = @(@{
                networkId = 'ui-review-network'; subnet = $Subnet; address = $address
                hostname = $Name; vendor = 'Example Devices'; classification = $classification
                ports = $Ports; latency = $Latency; probeDuration = '00:00:00.002'
                firstSeen = $seen; lastSeen = $seen; lastChecked = $seen; present = $true
                serviceAdvertisements = $Advertisements
            }); scanHistory = @()
        }
        $results.Add(@{
            address = $address; macAddress = $mac; deviceName = $Name; vendorName = 'Example Devices'
            status = 0; roundtripTimeMilliseconds = $Latency; probeDuration = '00:00:00.002'
            classification = $classification; openPorts = $Ports; serviceAdvertisements = $Advertisements
        })
    }
    function New-DocumentationAdvertisement([string] $Type, [string] $Label, [string] $Role, [int] $Port, [int] $Verification) {
        @{
            protocol = 0; serviceType = $Type; serviceLabel = $Label; role = $Role
            instanceName = $Label; host = 'example-device.local'; port = $Port; transport = 0
            observedAt = $seen; verification = $Verification
        }
    }
    Add-DocumentationDevice 1 'Home router' 4 3 1 @(@{ port = 443; serviceName = 'HTTPS' })
    Add-DocumentationDevice 2 'Workstation Ethernet' 1 1 3 @(@{ port = 445; serviceName = 'SMB' })
    Add-DocumentationDevice 3 'Workstation Wi-Fi' 1 1 6 @(@{ port = 445; serviceName = 'SMB' })
    Add-DocumentationDevice 4 'Android phone' 2 2 12
    Add-DocumentationDevice 5 'iPad' 3 5 8
    Add-DocumentationDevice 6 'Living room TV' 6 2 5 @(@{ port = 8009; serviceName = 'Cast' })
    Add-DocumentationDevice 7 'Office printer' 5 0 4 @(@{ port = 631; serviceName = 'IPP' }, @{ port = 9100; serviceName = 'Printer' })
    Add-DocumentationDevice 8 'Home NAS' 7 3 2 @(@{ port = 443; serviceName = 'HTTPS' }, @{ port = 445; serviceName = 'SMB' })
    Add-DocumentationDevice 9 'Kitchen speaker' 6 0 $null @(@{ port = 8009; serviceName = 'Cast (advertised)' }) @(
        (New-DocumentationAdvertisement '_googlecast._tcp.local' 'Google Cast' 'Cast receiver' 8009 1),
        (New-DocumentationAdvertisement '_spotify-connect._tcp.local' 'Spotify Connect' 'Spotify Connect playback endpoint' 4070 3))
    Add-DocumentationDevice 10 'Hue bridge' 9 0 $null @() @(
        (New-DocumentationAdvertisement '_hue._tcp.local' 'Philips Hue' 'Hue bridge service' 443 2))

    $inventory = Join-Path $Directory 'inventory.json'
    $snapshot = Join-Path $Directory 'snapshot.json'
    $hallway = '10000000-0000-0000-0000-000000000001'
    $office = '10000000-0000-0000-0000-000000000002'
    $livingRoom = '10000000-0000-0000-0000-000000000003'
    $rooms = @(
        @{ id = $hallway; name = 'Hallway'; shortName = 'H'; iconId = 'room' },
        @{ id = $office; name = 'Office'; shortName = 'OF'; iconId = 'room' },
        @{ id = $livingRoom; name = 'Living room'; shortName = 'LR'; iconId = 'room' })
    $assignments = @{}
    foreach ($index in @(1, 8, 10)) { $assignments[('0011225500{0:X2}' -f $index)] = @{ roomId = $hallway } }
    foreach ($index in @(2, 3, 7)) { $assignments[('0011225500{0:X2}' -f $index)] = @{ roomId = $office } }
    foreach ($index in @(6, 9)) { $assignments[('0011225500{0:X2}' -f $index)] = @{ roomId = $livingRoom } }
    @{ version = 4; data = @{
        revision = [Guid]::NewGuid().ToString(); devices = $devices; names = @{}; classifications = @{}
        peopleRooms = @{ people = @(); rooms = $rooms; assignments = $assignments }
        virtualDevices = @(); discoveryBaselines = @()
    } } | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $inventory -Encoding utf8
    @{ version = 4; subnet = $Subnet; completedAt = $seen; duration = '00:00:02.500'
        results = @($results.ToArray()) } |
        ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $snapshot -Encoding utf8
    return @{ Inventory = $inventory; Snapshot = $snapshot }
}

function Add-DocumentationDevicesLink([string] $Inventory) {
    $store = [FingVibe.Core.Storage.DeviceInventoryStore]::new([IO.Path]::ChangeExtension($Inventory, '.sqlite'))
    $token = [Threading.CancellationToken]::None
    $loaded = $store.LoadMetadataAsync($token).GetAwaiter().GetResult()
    $identification = [FingVibe.Core.Models.DeviceClassificationOverride]::new(
        [FingVibe.Core.Models.DeviceOperatingSystem]::Windows,
        [FingVibe.Core.Models.DeviceType]::Computer)
    $assignment = [FingVibe.Core.Models.DeviceAssignment]::new($null, [Guid]'10000000-0000-0000-0000-000000000002')
    $choices = [FingVibe.Core.Models.LinkedDeviceChoices]::new('Workstation', $identification, $assignment, $null)
    $linked = $loaded.LinkDevices('001122550002', '001122550003', $choices, [DateTimeOffset]::UtcNow)
    $null = $store.SaveAsync($linked, $loaded.Revision, $token).GetAwaiter().GetResult()
}
