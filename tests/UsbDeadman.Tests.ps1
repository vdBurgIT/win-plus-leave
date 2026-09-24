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

Describe 'Get-UdNextStep (the deadman switch)' {
    It 'arms when the key appears' {
        $s = Get-UdNextStep -State Disarmed -Present $true
        $s.State | Should -Be 'Armed'; $s.Fire | Should -BeFalse; $s.Changed | Should -BeTrue
    }
    It 'fires once when the armed key disappears, and disarms' {
        $s = Get-UdNextStep -State Armed -Present $false
        $s.State | Should -Be 'Disarmed'; $s.Fire | Should -BeTrue
    }
    It 'does not fire again while the key stays away' {
        (Get-UdNextStep -State Disarmed -Present $false).Fire | Should -BeFalse
    }
    It 'stays armed while the key stays in' {
        $s = Get-UdNextStep -State Armed -Present $true
        $s.State | Should -Be 'Armed'; $s.Changed | Should -BeFalse
    }
    It 'walks a whole day: in, out (lock), out, in (re-arm), out (lock)' {
        $state = 'Disarmed'; $fired = 0
        foreach ($p in $true, $false, $false, $true, $true, $false) {
            $step = Get-UdNextStep -State $state -Present $p
            if ($step.Fire) { $fired++ }
            $state = $step.State
        }
        $fired | Should -Be 2
        $state | Should -Be 'Disarmed'
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
