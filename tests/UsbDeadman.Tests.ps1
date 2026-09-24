#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The logic that decides whether to lock is pure and runs anywhere, so it is
# tested here without Windows and without pulling a key out of a laptop.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\UsbDeadman\UsbDeadman.psm1') -Force
}

Describe 'ConvertFrom-UdInstanceId' {
    It 'reads vendor, product and a serial' {
        $id = ConvertFrom-UdInstanceId -InstanceId 'USB\VID_1050&PID_0407\0012345678'
        $id.VendorId | Should -Be '1050'
        $id.ProductId | Should -Be '0407'
        $id.Last | Should -Be '0012345678'
        $id.HasSerial | Should -BeTrue
    }
    It 'recognises a port location as no serial' {
        (ConvertFrom-UdInstanceId -InstanceId 'USB\VID_1050&PID_0407\5&2A1B3C4D&0&2').HasSerial | Should -BeFalse
    }
    It 'upper-cases hex ids' {
        (ConvertFrom-UdInstanceId -InstanceId 'USB\VID_abcd&PID_ef01\X1').VendorId | Should -Be 'ABCD'
    }
    It 'ignores interfaces and non-USB devices' {
        ConvertFrom-UdInstanceId -InstanceId 'USB\VID_1050&PID_0407&MI_00\6&1&0&0000' | Should -BeNullOrEmpty
        ConvertFrom-UdInstanceId -InstanceId 'HID\VID_1050&PID_0407&MI_00\7&1&0&0000' | Should -BeNullOrEmpty
        ConvertFrom-UdInstanceId -InstanceId '' | Should -BeNullOrEmpty
    }
}

Describe 'Test-UdDeviceMatch' {
    It 'matches any YubiKey with the default rule' {
        $rule = [pscustomobject]@{ VendorId = '1050'; ProductId = '*'; Serial = '*' }
        Test-UdDeviceMatch -InstanceId 'USB\VID_1050&PID_0407\5&1&0&2' -Rule $rule | Should -BeTrue
        Test-UdDeviceMatch -InstanceId 'USB\VID_1050&PID_0406\0099' -Rule $rule | Should -BeTrue
    }
    It 'does not match another vendor' {
        $rule = [pscustomobject]@{ VendorId = '1050'; ProductId = '*'; Serial = '*' }
        Test-UdDeviceMatch -InstanceId 'USB\VID_0781&PID_5581\4C530001' -Rule $rule | Should -BeFalse
    }
    It 'pins a serial, case-insensitively' {
        $rule = [pscustomobject]@{ VendorId = '0781'; ProductId = '5581'; Serial = '4c530001' }
        Test-UdDeviceMatch -InstanceId 'USB\VID_0781&PID_5581\4C530001' -Rule $rule | Should -BeTrue
        Test-UdDeviceMatch -InstanceId 'USB\VID_0781&PID_5581\4C530002' -Rule $rule | Should -BeFalse
    }
    It 'never matches a pinned serial against a port location' {
        $rule = [pscustomobject]@{ VendorId = '1050'; ProductId = '0407'; Serial = '5*' }
        Test-UdDeviceMatch -InstanceId 'USB\VID_1050&PID_0407\5&2A1B&0&2' -Rule $rule | Should -BeFalse
    }
}

Describe 'Find-UdTrustedDevice' {
    It 'returns only the trusted devices, once each' {
        $devices = @(
            [pscustomobject]@{ InstanceId = 'USB\VID_1050&PID_0407\5&1&0&2'; Name = 'YubiKey' },
            [pscustomobject]@{ InstanceId = 'USB\VID_046D&PID_C52B\6&2&0&3'; Name = 'Mouse' }
        )
        $rules = @(
            [pscustomobject]@{ VendorId = '1050'; ProductId = '*'; Serial = '*' },
            [pscustomobject]@{ VendorId = '1050'; ProductId = '0407'; Serial = '*' }
        )
        $found = @(Find-UdTrustedDevice -Devices $devices -Rules $rules)
        $found.Count | Should -Be 1
        $found[0].Name | Should -Be 'YubiKey'
    }
    It 'returns nothing when nothing is plugged in' {
        @(Find-UdTrustedDevice -Devices @() -Rules @([pscustomobject]@{ VendorId = '1050'; ProductId = '*'; Serial = '*' })).Count | Should -Be 0
    }
}

Describe 'New-UdRuleFromInstanceId' {
    It 'keeps the serial when there is one' {
        $r = New-UdRuleFromInstanceId -InstanceId 'USB\VID_0781&PID_5581\4C530001' -Name 'Stick'
        $r.Serial | Should -Be '4C530001'
        $r.Name | Should -Be 'Stick'
    }
    It 'falls back to the model when Windows only knows the port' {
        $r = New-UdRuleFromInstanceId -InstanceId 'USB\VID_1050&PID_0407\5&2A1B&0&2'
        $r.Serial | Should -Be '*'
        $r.Name | Should -Be 'USB 1050:0407'
    }
    It 'refuses something that is not a USB device' {
        { New-UdRuleFromInstanceId -InstanceId 'HID\VID_1050' } | Should -Throw
    }
}

Describe 'Invoke-UdTick (the deadman switch)' {
    BeforeAll {
        $cfg = [pscustomobject]@{ ArmDelaySeconds = 5; MaxFiresPerWindow = 3; FlapWindowMinutes = 10 }
        # Plays a timeline of (clock time, key present?) through the switch and
        # returns what happened. Times are on one arbitrary day.
        function Invoke-Timeline {
            param([object[]] $Timeline, $Config = $cfg)
            $tick = New-UdTickState
            $fires = @()
            foreach ($t in $Timeline) {
                $now = [datetime]::ParseExact("2026-09-24 $($t[0])", 'yyyy-MM-dd HH:mm:ss', $null)
                $tick = Invoke-UdTick -Tick $tick -Now $now -Present ([bool]$t[1]) -Config $Config
                if ($tick.Fire) { $fires += $t[0] }
            }
            [pscustomobject]@{ Fires = $fires; State = $tick.State }
        }
    }

    It 'starts disarmed and remembers nothing from earlier logons' {
        (New-UdTickState).State | Should -Be 'Disarmed'
    }

    It 'the bad day: key in, walk away (lock), back with a broken key, unlock: no second lock' {
        $r = Invoke-Timeline @(
            @('08:00:00', $true),   # sign in with the key
            @('08:00:06', $true),   # armed after 5 s
            @('12:30:00', $false),  # key pulled, walk away: LOCK
            @('13:15:00', $false),  # back, the key is broken, unlock with PIN
            @('13:15:05', $false),
            @('17:00:00', $false)   # rest of the afternoon without a key
        )
        $r.Fires | Should -Be @('12:30:00')
        $r.State | Should -Be 'Disarmed'
    }

    It 'never locks a logon without the key, even after a morning with it' {
        # A new logon is a new process: fresh state, no memory of the morning.
        $r = Invoke-Timeline @(@('14:00:00', $false), @('14:00:10', $false), @('18:00:00', $false))
        $r.Fires.Count | Should -Be 0
    }

    It 'does not arm on a broken key that blinks in and out' {
        $timeline = foreach ($s in 0..59) { , @(('09:00:{0:D2}' -f $s), ($s % 2 -eq 0)) }
        $r = Invoke-Timeline $timeline
        $r.Fires.Count | Should -Be 0
        $r.State | Should -Be 'Disarmed'
    }

    It 'arms only after the key has been in for the full delay' {
        $tick = New-UdTickState
        $t0 = Get-Date '2026-09-24 09:00:00'
        (Invoke-UdTick -Tick $tick -Now $t0 -Present $true -Config $cfg).State | Should -Be 'Disarmed'
        $tick = Invoke-UdTick -Tick $tick -Now $t0 -Present $true -Config $cfg
        (Invoke-UdTick -Tick $tick -Now $t0.AddSeconds(4) -Present $true -Config $cfg).State | Should -Be 'Disarmed'
        (Invoke-UdTick -Tick $tick -Now $t0.AddSeconds(5) -Present $true -Config $cfg).State | Should -Be 'Armed'
    }

    It 're-arms when a working key comes back, and locks again when it leaves' {
        $r = Invoke-Timeline @(
            @('08:00:00', $true), @('08:00:05', $true),
            @('10:00:00', $false),                    # lock
            @('10:30:00', $true), @('10:30:05', $true), # back in: re-armed
            @('11:00:00', $false)                     # lock
        )
        $r.Fires | Should -Be @('10:00:00', '11:00:00')
    }

    It 'stands down after 3 locks in 10 minutes: a faulty key must not lock you out all day' {
        $timeline = @()
        foreach ($m in 0..5) {
            # works for 6 seconds, then drops: arms, fires, again and again
            $timeline += , @(('09:{0:D2}:00' -f $m), $true)
            $timeline += , @(('09:{0:D2}:06' -f $m), $true)
            $timeline += , @(('09:{0:D2}:30' -f $m), $false)
        }
        $r = Invoke-Timeline $timeline
        $r.Fires.Count | Should -Be 3
        $r.State | Should -Be 'Suspended'
    }

    It 'forgets old locks once they fall out of the window' {
        $r = Invoke-Timeline @(
            @('08:00:00', $true), @('08:00:05', $true), @('08:01:00', $false),
            @('08:02:00', $true), @('08:02:05', $true), @('08:03:00', $false),
            @('11:00:00', $true), @('11:00:05', $true), @('11:01:00', $false)
        )
        $r.Fires.Count | Should -Be 3
        $r.State | Should -Be 'Disarmed'
    }

    It 'never stands down when the breaker is switched off' {
        $off = [pscustomobject]@{ ArmDelaySeconds = 0; MaxFiresPerWindow = 0; FlapWindowMinutes = 10 }
        $timeline = foreach ($s in 0..19) { , @(('09:00:{0:D2}' -f $s), ($s % 2 -eq 0)) }
        $r = Invoke-Timeline $timeline -Config $off
        $r.Fires.Count | Should -Be 10
        $r.State | Should -Be 'Disarmed'
    }
}

Describe 'Get-UdConfig' {
    BeforeEach { $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ud-" + [guid]::NewGuid() + '.json') }
    AfterEach { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }

    It 'uses the defaults without a file' {
        $c = Get-UdConfig -Path $tmp
        $c.Action | Should -Be 'Lock'
        $c.Devices[0].VendorId | Should -Be '1050'
    }
    It 'reads the shipped example config' {
        $c = Get-UdConfig -Path (Join-Path $PSScriptRoot '..\config.example.json')
        $c.Action | Should -Be 'Lock'
        $c.PollSeconds | Should -Be 5
    }
    It 'fills missing fields in a rule with wildcards' {
        '{"Devices":[{"VendorId":"0781"}]}' | Set-Content -LiteralPath $tmp
        $c = Get-UdConfig -Path $tmp
        $c.Devices[0].ProductId | Should -Be '*'
        $c.Devices[0].Serial | Should -Be '*'
        $c.Devices[0].Name | Should -Not -BeNullOrEmpty
    }
    It 'refuses an unknown action instead of silently doing nothing' {
        '{"Action":"SelfDestruct"}' | Set-Content -LiteralPath $tmp
        { Get-UdConfig -Path $tmp } | Should -Throw '*Invalid Action*'
    }
    It 'refuses an empty device list' {
        '{"Devices":[]}' | Set-Content -LiteralPath $tmp
        { Get-UdConfig -Path $tmp } | Should -Throw '*No devices configured*'
    }
    It 'clamps silly numbers' {
        '{"PollSeconds":0,"DebounceMilliseconds":-5}' | Set-Content -LiteralPath $tmp
        $c = Get-UdConfig -Path $tmp
        $c.PollSeconds | Should -Be 1
        $c.DebounceMilliseconds | Should -Be 0
    }
}

Describe 'Invoke-UdAction' {
    It 'does nothing under -WhatIf' {
        { Invoke-UdAction -Action Lock -WhatIf } | Should -Not -Throw
    }
    It 'only accepts known actions' {
        { Invoke-UdAction -Action Format -WhatIf } | Should -Throw
    }
}
