@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=(Get-Content -LiteralPath '%~f0' -Raw) -split ('#'+'PS#'); $h=$p[2]; iex $p[1]"
pause
exit /b
#PS#
& {
# ===== EDIT THIS: game folder to verify =====
$dest = "C:\Games\MW3"
# =============================================

$langs = [ordered]@{
    "1" = @{ Name = "English"; Depot = "depot_42683" }
    "2" = @{ Name = "Spanish"; Depot = "depot_42684" }
    "3" = @{ Name = "German";  Depot = "depot_42685" }
    "4" = @{ Name = "French";  Depot = "depot_42686" }
    "5" = @{ Name = "Italian"; Depot = "depot_42687" }
}
$baseDepot = "depot_42682"

# Steam console command to redownload each depot
$cmds = @{
    "depot_42682" = "download_depot 42690 42682 6067691797475126381"
    "depot_42683" = "download_depot 42690 42683 6381783964590594065"
    "depot_42684" = "download_depot 42690 42684 2528087911534752870"
    "depot_42685" = "download_depot 42690 42685 3657601166463056212"
    "depot_42686" = "download_depot 42690 42686 7088412265150636376"
    "depot_42687" = "download_depot 42690 42687 8273360275068894160"
}

Write-Host "Which language pack do you want to verify?"
Write-Host ""
foreach ($k in $langs.Keys) { Write-Host ("  [{0}] {1}" -f $k, $langs[$k].Name) }
Write-Host ""
Write-Host "Press a number (1-5), or Q to quit."
$choice = $null
while ($true) {
    $key = [Console]::ReadKey($true)
    $c = [string]$key.KeyChar
    if ($c -eq "q" -or $c -eq "Q") { return }
    if ($langs.Contains($c)) { $choice = $langs[$c]; break }
}
Write-Host ""
Write-Host "Selected: $($choice.Name). Verifying base game ($baseDepot) + $($choice.Name) ($($choice.Depot)) in $dest"
Write-Host ""
$targets = [ordered]@{}
$targets[$baseDepot] = $dest
$targets[$choice.Depot] = $dest

# Load embedded hashes, grouped by depot (lines starting with === name)
$expected = @{}
$cur = $null
foreach ($line in ($h -split "`r?`n")) {
    if ($line -match '^===\s+(\S+)') { $cur = $Matches[1]; $expected[$cur] = New-Object Collections.Generic.List[object]; continue }
    if ($cur -and $line -match '^([0-9A-Fa-f]{32})\s+(.+?)\s*$') {
        $expected[$cur].Add(@{ Hash = $Matches[1].ToUpperInvariant(); Path = $Matches[2] })
    }
}

function Test-Depot($name, $folder, $list) {
    $r = [ordered]@{ Name = $name; Folder = $folder; Total = $list.Count; Ok = 0; Missing = @(); Bad = @(); Errors = @(); Aborted = $false }
    if (-not (Test-Path -LiteralPath $folder)) { Write-Host "[$name] Folder not found: $folder"; $r.Aborted = $true; return $r }
    $root = (Resolve-Path -LiteralPath $folder).Path.TrimEnd([char]92)

    $present = New-Object Collections.Generic.List[object]
    $total = 0L
    foreach ($e in $list) {
        $full = Join-Path $root $e.Path
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $len = (Get-Item -LiteralPath $full -Force).Length
            $present.Add(@{ Rel = $e.Path; Full = $full; Hash = $e.Hash; Len = $len })
            $total += $len
        } else { $r.Missing += $e.Path }
    }
    Write-Host ("[{0}] Hashing {1} of {2} files ({3:N0} MB) in {4}" -f $name, $present.Count, $list.Count, ($total / 1MB), $root)

    $buf = New-Object byte[] 4MB
    $done = 0L; $last = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($f in $present) {
        $md5 = [Security.Cryptography.MD5]::Create()
        try {
            $fs = [IO.File]::Open($f.Full, 'Open', 'Read', 'ReadWrite')
            try {
                while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
                    [void]$md5.TransformBlock($buf, 0, $n, $null, 0)
                    $done += $n
                    if (($sw.ElapsedMilliseconds - $last) -gt 250) {
                        $last = $sw.ElapsedMilliseconds
                        Write-Progress -Activity "Verifying $name" -Status ("{0:N0} / {1:N0} MB - {2}" -f ($done / 1MB), ($total / 1MB), $f.Rel) -PercentComplete ([int](100 * $done / [Math]::Max($total, 1)))
                    }
                }
                [void]$md5.TransformFinalBlock($buf, 0, 0)
                $got = [BitConverter]::ToString($md5.Hash).Replace('-', '')
                if ($got -ne $f.Hash) { $r.Bad += $f.Rel } else { $r.Ok++ }
            } finally { $fs.Close() }
        } catch { $r.Errors += "$($f.Rel) ($($_.Exception.Message))" }
        finally { $md5.Dispose() }
    }
    Write-Progress -Activity "Verifying $name" -Completed
    return $r
}

$results = @()
foreach ($name in $targets.Keys) {
    if (-not $expected.ContainsKey($name)) { Write-Host "No embedded hashes for $name"; continue }
    $results += ,(Test-Depot $name $targets[$name] $expected[$name])
    Write-Host ""
}

# Summary and report
$report = New-Object Collections.Generic.List[string]
$allPass = $true
$redo = New-Object Collections.Generic.List[string]
Write-Host "================ SUMMARY ================"
foreach ($r in $results) {
    $pass = (-not $r.Aborted) -and $r.Missing.Count -eq 0 -and $r.Bad.Count -eq 0 -and $r.Errors.Count -eq 0
    if (-not $pass) { $allPass = $false }
    $status = if ($pass) { "PASS" } else { "FAIL" }
    Write-Host ("{0}: {1}  ({2}/{3} match, {4} missing, {5} wrong hash, {6} unreadable)" -f $r.Name, $status, $r.Ok, $r.Total, $r.Missing.Count, $r.Bad.Count, $r.Errors.Count)
    foreach ($pair in @(@("Missing", $r.Missing), @("Wrong hash", $r.Bad), @("Unreadable", $r.Errors))) {
        if ($pair[1].Count -gt 0) {
            Write-Host "  $($pair[0]) (first 10):"
            $pair[1] | Sort-Object | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" }
        }
    }
    if (-not $pass) {
        $fix = $cmds[$r.Name]
        Write-Host "  >> Redownload this depot in the Steam console:"
        Write-Host "     $fix"
        $redo.Add($fix)
    }
    $report.Add("=== $($r.Name) : $status   folder: $($r.Folder)")
    $report.Add("MISSING ($($r.Missing.Count))");    $r.Missing | Sort-Object | ForEach-Object { $report.Add("  $_") }
    $report.Add("WRONG HASH ($($r.Bad.Count))");     $r.Bad | Sort-Object | ForEach-Object { $report.Add("  $_") }
    $report.Add("UNREADABLE ($($r.Errors.Count))");  $r.Errors | Sort-Object | ForEach-Object { $report.Add("  $_") }
    $report.Add("")
}
if ($redo.Count -gt 0) {
    $report.Add("REDOWNLOAD COMMANDS (Steam console)")
    $redo | ForEach-Object { $report.Add("  $_") }
}
$reportFile = Join-Path ([Environment]::GetFolderPath('Desktop')) "verify_report.txt"
[IO.File]::WriteAllLines($reportFile, [string[]]$report)
Write-Host ""
if ($allPass) { Write-Host "RESULT: PASS - every depot matches." }
else {
    Write-Host "RESULT: FAIL - full report: $reportFile"
    Write-Host ""
    Write-Host "To fix, paste these into the Steam console (steam://open/console), wait for each to finish, then move the files again:"
    $redo | ForEach-Object { Write-Host "  $_" }
}
}
#PS#
=== depot_42682
AEFCEE5D1319929889267A470D261EDC  binkw32.dll
9B9F85066C28367FCA4DA1BD244CB885  dw-dev-ca.crt
7A6F28EE1288036910DD87E7FEBAB6C1  installscript.vdf
218A85235C072907709818CDD9AB83DC  logo.bmp
D68F0070C19AAC5E20CDF5E656F2E477  main\iw_00.iwd
83857A0216510AED5BECF429BABE6487  main\iw_01.iwd
A2ABB1C40F04A94A4663B70A9BFD7372  main\iw_02.iwd
586B1992197F65B6F4B0BC0900AFECBB  main\iw_03.iwd
B0EFD0232068E8D753735F0E826387B1  main\iw_04.iwd
88233515FDF936A1B490A085B4835AFA  main\iw_05.iwd
5AC28B6F63CC001D6063E091906A8784  main\iw_06.iwd
CD7C7C6B22B87F9DD9CB3468BE5E7E86  main\iw_07.iwd
7EB23E9770C36ED1772474E60A2041AC  main\iw_08.iwd
4BA31626119CD77C133EBFED3CABBBCA  main\iw_09.iwd
D00A52C8149F5DC16F2EA68971ED7160  main\iw_10.iwd
14813E0A2C13B60199AAED31E9D23507  main\iw_11.iwd
818BBDA5AF050A9D7177018ED5E6C8F9  main\iw_12.iwd
B532B5E879B532734BF41400F5D25FF6  main\iw_13.iwd
E9789CA526F53041AF282813DEDA8A8A  main\iw_14.iwd
B595269C49AA5379431361D153B49D38  main\iw_15.iwd
73B7AAE5C98C3707A093386D72EBE8AC  main\iw_16.iwd
11CE096E256C5438480E9621188DFA4C  main\iw_17.iwd
C4FCD2A5EC2B3F97400D935764D68146  main\iw_18.iwd
94CA90F2F07DE6F771C0C091C8FF75AA  main\iw_19.iwd
DC794933812FE77F721A56B2374645A3  main\iw_20.iwd
437C5DD11A0F3214B6E7ECC2FADF90B9  main\iw_21.iwd
2929FA6EE5D94C3D1FC658E22B61A2E4  main\iw_22.iwd
C59E6AE0FACBFE2D940D2925DFE2CDE9  main\iw_23.iwd
2F52FDA30BE61316958C9E04D3E517F3  main\video\berlin_tvanamorphic.bik
84296337C0A4B6834F008A25E8F32A96  main\video\black.bik
51DAC2F84364B1A66B7F7A28D967C9DE  main\video\castle_securitycam.bik
628BA0BC3CDF55978DFC7960D3A09675  main\video\castle_static.bik
1BF1D097F31520809BA604F4E85DCE72  main\video\castle_tv.bik
84296337C0A4B6834F008A25E8F32A96  main\video\default.bik
C0832F485122CFBE16B6A86C14CAA04F  main\video\dubai_pip01.bik
399379ED84BD08C0F112D21C0513DF28  main\video\dubai_pip02.bik
7FAAADCB35CEEA0D1FA939086646A66B  main\video\dubai_pip03.bik
FC67BC5884FD4804CACA5BA4461975F3  main\video\dubai_reflection.bik
857A7D99F3CF4B0D4E2EBB8B29BA9F3B  main\video\hijack_map_black.bik
8134293F2E46A47C15904A4A8C892F0C  main\video\india_flashback_1_1.bik
05A3EB0B49AD22B25738DE3AA7465A6A  main\video\india_flashback_2_1.bik
B1B8117B09CB1395E337D91CDA73D4CA  main\video\india_flashback_3_1.bik
7CA2ECC8A09B343D6CDC2A76822A16E1  main\video\india_flashback_4_1.bik
09D207A18D205193DD5D08CEAC4FAA2E  main\video\india_flashback_5_1.bik
5EDA78F4F6A14DEA5AB075DF600E4DA7  main\video\innocent_load.bik
C9638458565958AE0EE6F7002C3D0116  main\video\london_football.bik
B36B21B1E35F7CDA4377DF28FDF62C2E  main\video\london_posters.bik
1C534893682C0559EC3B43ECFFC17352  main\video\ny_manhattan_tvanamorphic.bik
D3AF17FB1D0F0A229645800163D9198D  main\video\opening.bik
6A5CA2DD05E75CF71612E6C1043D7697  main\video\payback_fade.bik
FD40FF7DE16CB92614552F7A1BF229DB  main\video\so_assassin_payback_load.bik
FD13AB88BA238124C422E1299D227ED4  main\video\so_assault_rescue_2_load.bik
EC2F9EB1EE4414A331D57CDE7DDD2507  main\video\so_deltacamp_load.bik
40B1AAA0BB977E39F11384EB9C19B677  main\video\so_heliswitch_berlin_load.bik
5AF60D4556FD2639524A9ED33558474E  main\video\so_ied_berlin_load.bik
0F6E8C347BB5AFD50F4D1C8695AF1219  main\video\so_jeep_paris_b_load.bik
DE41708D4705A74508C867D95372B5A5  main\video\so_killspree_paris_a_load.bik
D61B10C3FB686AED2E481FEC8DACA436  main\video\so_littlebird_payback_load.bik
1A497F060DA4BD3553E4CD512BC4A1B7  main\video\so_milehigh_hijack_load.bik
EAB9D44C388431EE546233904AEFD7B7  main\video\so_nyse_ny_manhattan_load.bik
ECF510BFA38FEB8AB8BB7274C1FC4934  main\video\so_rescue_hijack_load.bik
05F7DCD0EDF8020D0188993B08B9BC4A  main\video\so_stealth_prague_load.bik
9FAC968091068CBE6A1835FCCFE6072B  main\video\so_stealth_warlord_load.bik
DB7B189ED9D12713159E08A33209EA41  main\video\so_survival_mp_alpha_load.bik
FCB68A83D4268E00E27A15215FF11A1F  main\video\so_survival_mp_bootleg_load.bik
7823BD1DFC4CE2B3E4F075A68B3C4D0F  main\video\so_survival_mp_bravo_load.bik
3F5439864E5A45A69B4DB5CE4EE98D54  main\video\so_survival_mp_carbon_load.bik
0C47757699F130D75A62D30E1C56F10E  main\video\so_survival_mp_dome_load.bik
B0536E7965C77CB348B2EDD0068E24AF  main\video\so_survival_mp_exchange_load.bik
0A89F1601162A276AF94E6647DE5D0C4  main\video\so_survival_mp_hardhat_load.bik
98112B99AED45A5C7618BEEF2ECA2907  main\video\so_survival_mp_interchange_load.bik
16014BC2E2AD3A3FAF6A96F356D876BC  main\video\so_survival_mp_lambeth_load.bik
28E8858D421593290FB994E9697965E2  main\video\so_survival_mp_mogadishu_load.bik
73C7B3F1034CE38F50631D39368B4A4E  main\video\so_survival_mp_paris_load.bik
E4278FF13755534B516D461720EBA872  main\video\so_survival_mp_plaza2_load.bik
14DFC80800DC56148C1B177D113F78E3  main\video\so_survival_mp_radar_load.bik
4AEADBC165035C62DE3B4B2C4A567ED5  main\video\so_survival_mp_seatown_load.bik
148D623A335C92B5159016DC0A93327F  main\video\so_survival_mp_underground_load.bik
83F51756A29ECAE2D7657ABE91F9C047  main\video\so_survival_mp_village_load.bik
717DD388383C7554FA650268747FE280  main\video\so_timetrial_london_load.bik
EC2F9EB1EE4414A331D57CDE7DDD2507  main\video\so_trainer2_so_deltacamp_load.bik
203C6321377DD3ADCA857A5682AE41C6  main\video\so_zodiac2_ny_harbor_load.bik
DFB1245415673CC2AE588224AD6FDF1D  main\video\uav_fadeIn.bik
C1BC57F808D818E51CBFA044315A797A  main\video\uav_fadeOut.bik
BB900A99CC9AE289B6C8A2B8FF4B3ECE  main\video\ugv_startup.bik
EA3F326AD906A00CCD61B348F9B84A9E  miles\milesEq.flt
AFFAE4405794AE419BA720E5A9652B7E  miles\mssds3d.flt
36C0B69FBDC77336010BFBCBD573E23D  miles\mssdsp.flt
7567F5C7196E9ACC5B8CD2BD263E16ED  miles\msseax.flt
4C5F815A27F36275D29D21C105E3858E  miles\mssmp3.asi
D35EEA3AEAB508B9D15127A0C0CBBCB7  miles\mssvoice.asi
548F39629F991713624527757AFC5284  mss32.dll
FE9E6C4C7D7AA341A84F039D954560E9  Redist\DirectX\Apr2005_d3dx9_25_x64.cab
B7457F5D50176D38D36A2E2DC0429FD2  Redist\DirectX\Apr2005_d3dx9_25_x86.cab
3D797333854ABB64ABB6987AFE7B4CE9  Redist\DirectX\Apr2006_d3dx9_30_x64.cab
2BF0DEBD3D503EF601E5EE17BFBD139E  Redist\DirectX\Apr2006_d3dx9_30_x86.cab
579BEF95277D18191E77F631B9F886C8  Redist\DirectX\Apr2006_MDX1_x86.cab
78F5A0256E021167A4B15A2801B4AE58  Redist\DirectX\Apr2006_MDX1_x86_Archive.cab
84ACED4AA62F32D3746E32A73C39721F  Redist\DirectX\Apr2006_XACT_x64.cab
1407603EAACFF8BE5AC25DE29F29D267  Redist\DirectX\Apr2006_XACT_x86.cab
F4A3EF18CA06FB0C707664D298B434FE  Redist\DirectX\Apr2006_xinput_x64.cab
19C45FCC5C93C370F9B860C06E012E9A  Redist\DirectX\Apr2006_xinput_x86.cab
3FBA5D677F19C48F210CA5F6372D55AD  Redist\DirectX\APR2007_d3dx10_33_x64.cab
83033F2988EFE706886E5ABA492974D7  Redist\DirectX\APR2007_d3dx10_33_x86.cab
71C6A3C5C04093254E752E0D15AF1869  Redist\DirectX\APR2007_d3dx9_33_x64.cab
8E3E46DE4D520B4836B8776A2C771EAA  Redist\DirectX\APR2007_d3dx9_33_x86.cab
8ACBB49A7C2A97C12F63C16BDD8F7512  Redist\DirectX\APR2007_XACT_x64.cab
96F1EC4650282A0FD2DBD1EEA7F5CFD6  Redist\DirectX\APR2007_XACT_x86.cab
743B333C2DB3D4CF190FB39C29F3C346  Redist\DirectX\APR2007_xinput_x64.cab
C234DF417C9B12E2D31C7FD1E17E4786  Redist\DirectX\APR2007_xinput_x86.cab
C91AA9C752A7C46AA11101347209BA33  Redist\DirectX\Aug2005_d3dx9_27_x64.cab
5CDDDD58AE010E03ECC6CED128002291  Redist\DirectX\Aug2005_d3dx9_27_x86.cab
9CAFD440798ED33EC6561B09549AB263  Redist\DirectX\AUG2006_XACT_x64.cab
155B66797691647BBB935F0C0872C64D  Redist\DirectX\AUG2006_XACT_x86.cab
866DA8EDBC4E6ECBC4B04E2A77613AAD  Redist\DirectX\AUG2006_xinput_x64.cab
75B3D7D008DAD88064EC3D768FC60FCA  Redist\DirectX\AUG2006_xinput_x86.cab
A6E055FFABC8D8B2DEBBCC37E611078E  Redist\DirectX\AUG2007_d3dx10_35_x64.cab
61691EEE4A5E4BC6DFF8A26C68003918  Redist\DirectX\AUG2007_d3dx10_35_x86.cab
87B58E7B8172BF20BEEADA819496B154  Redist\DirectX\AUG2007_d3dx9_35_x64.cab
D9A1EE62D3072B3182BA87F05AA22BE0  Redist\DirectX\AUG2007_d3dx9_35_x86.cab
0E9AB7F465516FC690C79E230185CAAE  Redist\DirectX\AUG2007_XACT_x64.cab
2BDD2481E5982DE14EC680AA8B38347F  Redist\DirectX\AUG2007_XACT_x86.cab
B757DC9954F5456C542324ECB25ADDD2  Redist\DirectX\Aug2008_d3dx10_39_x64.cab
CC9EBCF0620AE732796871EF529AFEF9  Redist\DirectX\Aug2008_d3dx10_39_x86.cab
DE3CEC9D7A3CE447D4E8EE6C63B1460D  Redist\DirectX\Aug2008_d3dx9_39_x64.cab
73B607BB226C6E2A7F470317187BD551  Redist\DirectX\Aug2008_d3dx9_39_x86.cab
0F8573ACB2A0E300B97F6743E8A4E7A5  Redist\DirectX\Aug2008_XACT_x64.cab
2A8399C8F967263D487EA57289409866  Redist\DirectX\Aug2008_XACT_x86.cab
69478EC34EA5679088C40B8D349C3227  Redist\DirectX\Aug2008_XAudio_x64.cab
CCE65C41E6C2B87D0ECB5C666302F06D  Redist\DirectX\Aug2008_XAudio_x86.cab
A34039A6DCC7C42BE4D8716E8D73925E  Redist\DirectX\Aug2009_D3DCompiler_42_x64.cab
683D8C01C5B5E1E94B6B5901C45927DA  Redist\DirectX\Aug2009_D3DCompiler_42_x86.cab
A91957A8E5F8A7040690A1C2A6349E65  Redist\DirectX\Aug2009_d3dcsx_42_x64.cab
D4D7680AEE67FC5AE2BC26FBB228C95A  Redist\DirectX\Aug2009_d3dcsx_42_x86.cab
3C37874314F206C66C2F6BA1141C6BC2  Redist\DirectX\Aug2009_d3dx10_42_x64.cab
45C6E46ACE94AB79D196B394DE916428  Redist\DirectX\Aug2009_d3dx10_42_x86.cab
A94559CF5E72E296E14329173C9AA2A0  Redist\DirectX\Aug2009_d3dx11_42_x64.cab
07F2CA007A014F75D346D86E2AE5326E  Redist\DirectX\Aug2009_d3dx11_42_x86.cab
70CC5B4B3C39879D3E9058A33EF94F27  Redist\DirectX\Aug2009_d3dx9_42_x64.cab
D6E61DEF8B75A600F46605FC204D8E09  Redist\DirectX\Aug2009_d3dx9_42_x86.cab
7546CB34A87AAAA16E56D5998236BF13  Redist\DirectX\Aug2009_XACT_x64.cab
F5241686CEF2F3599D7E5115CB888599  Redist\DirectX\Aug2009_XACT_x86.cab
67373584C06CA2D6A9C872637868EDDE  Redist\DirectX\Aug2009_XAudio_x64.cab
57FC6049EF196BEDCC893738BC609DF8  Redist\DirectX\Aug2009_XAudio_x86.cab
95A871983DCCE1C8A4FD87483E1F047C  Redist\DirectX\Dec2005_d3dx9_28_x64.cab
C5455FAC40117333BA1AE32C8CB91633  Redist\DirectX\Dec2005_d3dx9_28_x86.cab
ECAFBF094869C785AAE0730ECE84C446  Redist\DirectX\DEC2006_d3dx10_00_x64.cab
65C0D1DD12D57B521553F1C8CFA41EE6  Redist\DirectX\DEC2006_d3dx10_00_x86.cab
5E89EA94E146F3AB247ED90B8F262BD0  Redist\DirectX\DEC2006_d3dx9_32_x64.cab
CFC6966680DF13A72E2284B67119CDAA  Redist\DirectX\DEC2006_d3dx9_32_x86.cab
E40FA2AE617E4810B457A3E598ABB856  Redist\DirectX\DEC2006_XACT_x64.cab
E3F08FD568A345B9C9F182E852DE219B  Redist\DirectX\DEC2006_XACT_x86.cab
EB701DEF7D0809E8DA765A752AB42BE5  Redist\DirectX\DSETUP.dll
D8FA7BB4FE10251A239ED75055DD6F73  Redist\DirectX\dsetup32.dll
4B4F83D1DD86314B65760F44F9C7A9B1  Redist\DirectX\dxdllreg_x86.cab
BF3F290275C21BDD3951955C9C3CF32C  Redist\DirectX\DXSETUP.exe
D495680ABA28CAAFC4C071A6D0FE55AC  Redist\DirectX\dxupdate.cab
F0215800A0031DD763C3CD7913717587  Redist\DirectX\Feb2005_d3dx9_24_x64.cab
7EE3C0E90D831041E6C845672660FE60  Redist\DirectX\Feb2005_d3dx9_24_x86.cab
57BACA471C5419CA43BFDA1B65774406  Redist\DirectX\Feb2006_d3dx9_29_x64.cab
09FE2721B43875CC085E0DA4470A47AD  Redist\DirectX\Feb2006_d3dx9_29_x86.cab
733C3A0ADA15D096265570E79044D1DA  Redist\DirectX\Feb2006_XACT_x64.cab
F66725E68F488C4379D8294449773136  Redist\DirectX\Feb2006_XACT_x86.cab
B6F585C314D27F04FE709139EE67411C  Redist\DirectX\FEB2007_XACT_x64.cab
99BB1DDA11228BA060988176E9C9130C  Redist\DirectX\FEB2007_XACT_x86.cab
DB47136A200E326174CE790359596EB6  Redist\DirectX\Feb2010_X3DAudio_x64.cab
88DFBB4C1876E80A1864265C61C7A7FD  Redist\DirectX\Feb2010_X3DAudio_x86.cab
D33D49A07398200CD12AD156F04AF20F  Redist\DirectX\Feb2010_XACT_x64.cab
F86C6B70038028DDEA66ED04EB51B50C  Redist\DirectX\Feb2010_XACT_x86.cab
1CBF47B0AE9356D6EC01E4123DEE28D4  Redist\DirectX\Feb2010_XAudio_x64.cab
64972172A756A0B255DBADB9792D0316  Redist\DirectX\Feb2010_XAudio_x86.cab
D795FD4FE6BACECBE706430E16F80A8B  Redist\DirectX\Jun2005_d3dx9_26_x64.cab
CC994475277A3D4FB3257C6230D12F8D  Redist\DirectX\Jun2005_d3dx9_26_x86.cab
36A6006B780B8EDBC497CB5ACAA13502  Redist\DirectX\JUN2006_XACT_x64.cab
23953B5D75968DABA6D2639969324853  Redist\DirectX\JUN2006_XACT_x86.cab
1B2084066A0FF3D37530DB9F94ADB11E  Redist\DirectX\JUN2007_d3dx10_34_x64.cab
47A295EECAC0609A1956CE3BA68B36AF  Redist\DirectX\JUN2007_d3dx10_34_x86.cab
CEE8DD3DB3C4329E494AE15D98F8726B  Redist\DirectX\JUN2007_d3dx9_34_x64.cab
C0D871CA7822160AFAC25814FD8621B7  Redist\DirectX\JUN2007_d3dx9_34_x86.cab
D819B3A479E14634C88A40CC93D69BE8  Redist\DirectX\JUN2007_XACT_x64.cab
BDD64C54E351A8716C0AD8A32A1E0241  Redist\DirectX\JUN2007_XACT_x86.cab
64A7277926E965AEE05E04E30F6BE400  Redist\DirectX\JUN2008_d3dx10_38_x64.cab
BA61F34B185E8D528A2BB62530FC6ED6  Redist\DirectX\JUN2008_d3dx10_38_x86.cab
E57D72F3AADD87B2B27216952D831E22  Redist\DirectX\JUN2008_d3dx9_38_x64.cab
5A7C86EF6F51C4F254C1D8CF0F2CFBE3  Redist\DirectX\JUN2008_d3dx9_38_x86.cab
F78A206008039DD2E99B190D883FE8EB  Redist\DirectX\JUN2008_X3DAudio_x64.cab
9D2F859A3FB01BD9A3A547E04C8B72D1  Redist\DirectX\JUN2008_X3DAudio_x86.cab
FC4BE653FCFDF85D3C9CD5917945EABA  Redist\DirectX\JUN2008_XACT_x64.cab
D00AB15B2A00346D5ECAD8D92573CEE2  Redist\DirectX\JUN2008_XACT_x86.cab
5AFA7D889A3D59436225B2F8C7F1EF30  Redist\DirectX\JUN2008_XAudio_x64.cab
A93550ACD0621DB2B06D9258EAE3BB06  Redist\DirectX\JUN2008_XAudio_x86.cab
0109C2931C4442C8192539F1991B6985  Redist\DirectX\Jun2010_D3DCompiler_43_x64.cab
F7F554AA613ECCF065575B8C69717EF7  Redist\DirectX\Jun2010_D3DCompiler_43_x86.cab
850AAFDDFEFEA671A2E1BBF1B65F2A8E  Redist\DirectX\Jun2010_d3dcsx_43_x64.cab
44DBA9557F956787B66F285776C3DCCB  Redist\DirectX\Jun2010_d3dcsx_43_x86.cab
2D9586B276A561924FF2335FCCAEE914  Redist\DirectX\Jun2010_d3dx10_43_x64.cab
A89B98AB89E0D4FF9DAE412D49E27C51  Redist\DirectX\Jun2010_d3dx10_43_x86.cab
96E7847A914AFCB489194940B06A5C23  Redist\DirectX\Jun2010_d3dx11_43_x64.cab
758C5A459978CB2C68A300A60DA153BE  Redist\DirectX\Jun2010_d3dx11_43_x86.cab
063FA6F7061324EAC1C4DE0350C20E80  Redist\DirectX\Jun2010_d3dx9_43_x64.cab
7749862C307E527366B6868326DB8198  Redist\DirectX\Jun2010_d3dx9_43_x86.cab
3753BA8FB15E0CB624B8CF1CF36FEDB6  Redist\DirectX\Jun2010_XACT_x64.cab
02DA71BFA4764677FFCB9DCC62714418  Redist\DirectX\Jun2010_XACT_x86.cab
EDEB828A8E54A9F3851007D80BC8DD6E  Redist\DirectX\Jun2010_XAudio_x64.cab
9D2DA3B1055120AF7C2995896F5D51ED  Redist\DirectX\Jun2010_XAudio_x86.cab
FA287A98400B25F435859F8AC0D4BE5B  Redist\DirectX\Mar2008_d3dx10_37_x64.cab
3314AA4EF508511B3B5042A7B013329B  Redist\DirectX\Mar2008_d3dx10_37_x86.cab
43EC986130C37B0F9D6E847C62E0B1C9  Redist\DirectX\Mar2008_d3dx9_37_x64.cab
CEC089E2479E50634E1CEA97B279EB86  Redist\DirectX\Mar2008_d3dx9_37_x86.cab
A540E888F2DD2898373416439E6CB057  Redist\DirectX\Mar2008_X3DAudio_x64.cab
7A575795249623DDE7ED7CCD5E7F63DD  Redist\DirectX\Mar2008_X3DAudio_x86.cab
D80F5F61D14479F28B412123ED3B2FD7  Redist\DirectX\Mar2008_XACT_x64.cab
B6DA8563ED50C905E00DFCCAF4B9585D  Redist\DirectX\Mar2008_XACT_x86.cab
D24D3BDBAC9931B6DFF3FA1401A06AD0  Redist\DirectX\Mar2008_XAudio_x64.cab
A641FDFF4A0A1F07B76BEC7A33673962  Redist\DirectX\Mar2008_XAudio_x86.cab
D51867CED279F38C07EBA99A3CC3F7C2  Redist\DirectX\Mar2009_d3dx10_41_x64.cab
8993E85E24C7B0E40B32FDA7C077B27B  Redist\DirectX\Mar2009_d3dx10_41_x86.cab
446A3FEF812883C260FA062873E3C111  Redist\DirectX\Mar2009_d3dx9_41_x64.cab
CEA31EBF2225612A2B5AD62EAFB01875  Redist\DirectX\Mar2009_d3dx9_41_x86.cab
523BB7846E3ED4284A3FE718B3E8D529  Redist\DirectX\Mar2009_X3DAudio_x64.cab
E6478900AB32D3A47FBB2B1CE92E1A38  Redist\DirectX\Mar2009_X3DAudio_x86.cab
E6849D2B74327EA210A722699962AA76  Redist\DirectX\Mar2009_XACT_x64.cab
9643FDEF5F24C96371F849208C06180A  Redist\DirectX\Mar2009_XACT_x86.cab
948A9BF38221E1DBEC758FC10ED4799C  Redist\DirectX\Mar2009_XAudio_x64.cab
342AF931588924E6DBCB77F65AB5249C  Redist\DirectX\Mar2009_XAudio_x86.cab
DFE34E327E3BD4A4F8C81D6B0B6A4AAC  Redist\DirectX\Nov2007_d3dx10_36_x64.cab
86695C393DAE55CE5D72E98E84824320  Redist\DirectX\Nov2007_d3dx10_36_x86.cab
C0D93B6491984793D9241F12C27BFCF2  Redist\DirectX\Nov2007_d3dx9_36_x64.cab
F6DF33E7335DBD4BB9E74B88F66764CF  Redist\DirectX\Nov2007_d3dx9_36_x86.cab
A8D4C000334AFB5CEEF9927A176BDCAE  Redist\DirectX\NOV2007_X3DAudio_x64.cab
A2459739CA33DA4CC696D051DA9899A6  Redist\DirectX\NOV2007_X3DAudio_x86.cab
80F3A65C31CCE23327FBA416F80792A4  Redist\DirectX\NOV2007_XACT_x64.cab
CB47EFF7550301CAE39F1CB9D7F30D74  Redist\DirectX\NOV2007_XACT_x86.cab
E8D8CF285B1A5B6A256413188BB275CB  Redist\DirectX\Nov2008_d3dx10_40_x64.cab
B633956D5274D9B031C8EA55B8F5701B  Redist\DirectX\Nov2008_d3dx10_40_x86.cab
7BABC8D6F8D4D044DB5153A8759A583A  Redist\DirectX\Nov2008_d3dx9_40_x64.cab
57176018DD94A20912C4424B1347DCD1  Redist\DirectX\Nov2008_d3dx9_40_x86.cab
68306F4A7426B8DCBE443D72BE0B6EEB  Redist\DirectX\Nov2008_X3DAudio_x64.cab
DF373F41729508C804A94069C220DE15  Redist\DirectX\Nov2008_X3DAudio_x86.cab
A495B57568A94B2C3DF47F5A64FDE631  Redist\DirectX\Nov2008_XACT_x64.cab
ABB59DD97F8964C2E8E45FBF7518B972  Redist\DirectX\Nov2008_XACT_x86.cab
0552FB71D30788167C1B3A1FBAA59B45  Redist\DirectX\Nov2008_XAudio_x64.cab
795E745F1A111CBD6512C4B0360538B4  Redist\DirectX\Nov2008_XAudio_x86.cab
C39E4358CEA9538AB1D4B842DA669BC6  Redist\DirectX\Oct2005_xinput_x64.cab
B296431A5DFFF596FEF2F04B4F36362A  Redist\DirectX\Oct2005_xinput_x86.cab
7412C05A3CF0DBF5C1B73D34419AB5B6  Redist\DirectX\OCT2006_d3dx9_31_x64.cab
0107AE9DDC91F279966BB74FAE686FFC  Redist\DirectX\OCT2006_d3dx9_31_x86.cab
265E3D8E5635179004742AA3AF2E05CF  Redist\DirectX\OCT2006_XACT_x64.cab
09AD0F82D92213B7D7EAA9E3B2268FE5  Redist\DirectX\OCT2006_XACT_x86.cab
5689D43C3B201DD3810FA3BBA4A6476A  Redist\vcredist_x86.exe
83882B0984953B9F60F8AC95178751DD  splash.bmp
F9516209E964458E94168D50A4A0B33C  steam_api.dll
C4835E469EA0108B888BE9012DEE7254  SteamAPIUpdater.dll
28574C2CD6DB375EDF0A90F1BD8C2419  steamclient.dll
4AA99686D76BD6285CCDBE0EBCBC67ED  tier0_s.dll
0DE6921BA5D89824053B76F65624AC9A  UpdateDLLWrapper.dll
F7FD0ACAD4284DAB38BA9E4B6E503F19  vstdlib_s.dll
=== depot_42683
E22967637A0B4AEE942170140D51539E  localization.txt
3D8E26AC58C26CB706321AD12BAC80B0  main\localized_english_iw00.iwd
9031C27FD24035E32DFB1FB3C55EB632  main\localized_english_iw01.iwd
C891C871C3F0A83D40CBDF12DEA29FB9  main\localized_english_iw02.iwd
04703DCF6695B390DB9DAE16A8D1FDC3  main\localized_english_iw03.iwd
1E07AC0011109A1A4D8BCC50DA906F0C  main\localized_english_iw04.iwd
33D2245E59D5FA04D3CB9B28ED5B8AF5  main\video\castle_load.bik
CD5061132DFCD74F82AB9D5B2D8CF967  main\video\hamburg_load.bik
F770C648105775E7BA3BA633E9CE754B  main\video\hijack_load.bik
129B89FA52C1FD968F00E287F99EF39C  main\video\london_load.bik
D6C62E911F4ABCFB498B0CE31007F073  main\video\paris_ac130_load.bik
F3284E629E8D0A51192F25B90ACD6B73  main\video\prague_escape_load.bik
00C26C0EF0A151438CD6DF3F2C3B9292  main\video\prologue_select_load.bik
AD9DB770307F407CC8654A6A544ECDA6  main\video\rescue_2_load.bik
37758551FE8038D98A3D862903AD4393  main\video\sp_berlin_load.bik
AA84F3F8519C2AFB1C1EF4454A86DD09  main\video\sp_dubai_load.bik
9AA737F09D508A5B82A5103F86AFD219  main\video\sp_intro_load.bik
9EC9130C98EEAA5C30A30CCC4CC1FD42  main\video\sp_ny_harbor_load.bik
ED5DA0EAEB68D22B126ADD435EBEDFD6  main\video\sp_ny_manhattan_load.bik
1863EAD7CCE56333CB043CA5EED6BBA9  main\video\sp_paris_a_load.bik
42327007D7FEDFC7969063A874C09431  main\video\sp_paris_b_load.bik
5CBAB1A8EEEDD96F0ABE36D05DB43DCD  main\video\sp_payback_load.bik
851C881A434CD73930FCCC5EFBCED637  main\video\sp_prague_load.bik
E6C2BFD9A06B185BE57CF77D44DE36B0  main\video\sp_warlord_load.bik
26E267AD88931A8B1782A348C58E2844  main\video\startup.bik
3E80BA55855E2851DA159151006D7558  zone\english\berlin.ff
7447787D9605762812C28AD644FC39A9  zone\english\castle.ff
87549997B8D5E89982DAD20594E520F6  zone\english\code_post_gfx.ff
F99DE016E1B658A37034653572928BBA  zone\english\code_post_gfx_mp.ff
4804545A79233F37660D9B467542324B  zone\english\code_pre_gfx.ff
1C599A45304F0C0A768ABAC680609992  zone\english\code_pre_gfx_mp.ff
8E82EBAD8162052E9CEF1BC760E21FEE  zone\english\common.ff
78784ABB5391C9D50A7364BC0C9100E4  zone\english\common_mp.ff
5F488B1256E9CDCC4E757EF691C414D6  zone\english\common_specialops.ff
01C7213CFBCA1096CCC9D0D191B6BB68  zone\english\common_survival.ff
6445919531A705F71A9DB169F26B3463  zone\english\dubai.ff
53DF18238A3C083676FAD4A230F0CE0A  zone\english\hamburg.ff
E5EF9C1DA1C33A3F7AB2BA01D559D763  zone\english\hijack.ff
DFC0E5422CE5F45ACDED28929C8B9678  zone\english\innocent.ff
F1153516B2E5432C225398B5B9041CDA  zone\english\intro.ff
11E7B91F0D8B22FD5349BAB13233770C  zone\english\localized_code_post_gfx_mp.ff
E611C4485337499D62D44AA4F6CAF9F1  zone\english\localized_code_pre_gfx_mp.ff
A75A4D45B0DEFA9F1C7186C013200546  zone\english\localized_common_mp.ff
4514DF4E2FA05B02E320435B346B1360  zone\english\localized_ui_mp.ff
284B606EEB9DA04989BA1FB36100961A  zone\english\london.ff
924F77BCD187BD1CBCB0D150B3A64A48  zone\english\mp_alpha.ff
E62BD55EE91A68C285CB150056F32D89  zone\english\mp_alpha_load.ff
ED9BFC4FAED0597617FE7C64431566FE  zone\english\mp_bootleg.ff
3493149A6039BA602105DD69AC95F70B  zone\english\mp_bootleg_load.ff
A05C18DB92552BD2BCAE6526405ECC02  zone\english\mp_bravo.ff
9777FB3AAF0B9FC0B60C25B023AB4C94  zone\english\mp_bravo_load.ff
24E8078702B4C1E53422D9EC4AD84A81  zone\english\mp_carbon.ff
A8E93B6211D2B32988D12973524D2B18  zone\english\mp_carbon_load.ff
227972F7C04125FB6F3C3C681A1BC972  zone\english\mp_dome.ff
4936FDFE7589877FD71F31E9789D4BAB  zone\english\mp_dome_load.ff
F323DD8DA2E3BB76C8E9FD4D526B2966  zone\english\mp_exchange.ff
5F02FD52A19D879E85F8FC4B8FF83F17  zone\english\mp_exchange_load.ff
7BD66C933F57BDBF98691242BC42DF91  zone\english\mp_hardhat.ff
239CABA8A4799FCFFC33A73B6C69A391  zone\english\mp_hardhat_load.ff
2AD0C193175C066F21245B8E9B8602BC  zone\english\mp_interchange.ff
00F25FADCC0FE3B28614142163E64805  zone\english\mp_interchange_load.ff
E8D70614AFA15E54AD00BCD7C375FC52  zone\english\mp_lambeth.ff
6FCF1BFE900CE16FE58601C277BAF037  zone\english\mp_lambeth_load.ff
8726937A43556CDDD0AF3790F578DF84  zone\english\mp_mogadishu.ff
710A70169566AD1480146215DC6FB6B6  zone\english\mp_mogadishu_load.ff
D6E16967ADB121412CD6E18F6B0222C5  zone\english\mp_paris.ff
CC7C65E062FD46FC55916181C462112C  zone\english\mp_paris_load.ff
13E93C2C1323C2A8A8732D6EAEB33563  zone\english\mp_plaza2.ff
B8550154D4F46583161E88339262052B  zone\english\mp_plaza2_load.ff
B7D825082271D312217DB361960A36D2  zone\english\mp_radar.ff
EAF23673822DBF63888E849EA0C8889B  zone\english\mp_radar_load.ff
2AEF7E85303FEE15874F3E08D70C1EE9  zone\english\mp_seatown.ff
BC8A3B5254CDCCD999BC5C04A12680ED  zone\english\mp_seatown_load.ff
DAEC31370A7A5F129A1DF388F4B419FA  zone\english\mp_underground.ff
9E8AD503A7D16E23312F77E8CF197999  zone\english\mp_underground_load.ff
9F66E9F97CD14E03B70882B76B11B032  zone\english\mp_village.ff
C78E708C57FB3DF534FFCB9284433EC1  zone\english\mp_village_load.ff
2FA129AF5B2AD0B7665ACAEBC7AF4A5D  zone\english\ny_harbor.ff
597753E2AC24CA70872A246E1B908C93  zone\english\ny_manhattan.ff
52AF73465B4F64529FD945AA7A5E1A46  zone\english\paris_a.ff
BA4D9F1B8D66A78C87D9763F332E4352  zone\english\paris_ac130.ff
92D7B76C6DE4D13DAD483206042437F0  zone\english\paris_b.ff
A749553662D8EAA5EB45EF7D2C0C5F63  zone\english\patch.ff
6EF7A03009CDF8B970E244302A8DC7E0  zone\english\patch_hamburg.ff
D08023429BEFB047EE8BB131E6CDA08E  zone\english\patch_hijack.ff
7F4322F08DE24708A5520DDDEB96948D  zone\english\patch_innocent.ff
891393F4711D81DE578FD56A16F55960  zone\english\patch_london.ff
7BD6AB0FAFB0DE91BEEFDC3F4CFBDDFF  zone\english\patch_mp.ff
747DF38FEA6659C34F1CBDC53DCE94BB  zone\english\patch_mp_dome.ff
42B3B5AA215B3E612F7F878C4AFD3C13  zone\english\patch_mp_exchange.ff
9A958013C746A323FC43A63B57F31BC3  zone\english\patch_mp_lambeth.ff
63176BC3CF1EB8E72054B4601DE74117  zone\english\patch_mp_paris.ff
A6A6A2016AEC475001FBF82390C787C5  zone\english\patch_mp_radar.ff
2F71C56BAE3196820BDF9FEA0F7EB71A  zone\english\patch_mp_underground.ff
5389A85D41611FF68CDF0E3FFF51F71E  zone\english\patch_mp_village.ff
96E2E607566BCA008B9CC9C71E4452F9  zone\english\patch_paris_ac130.ff
621DF9E9BC61B0A1FA9D71DD23C93435  zone\english\patch_prague_escape.ff
21D2DCBA3E1F4E848EB6148C78ECD624  zone\english\patch_so_ied_berlin.ff
5AD38871CF76D2290737BBA3D9BF101C  zone\english\patch_so_littlebird_payback.ff
A192E4E028CE8403CC3A909B40FCA998  zone\english\patch_so_survival_mp_village.ff
316E0F310767AE4526ED71ACE4D2079C  zone\english\patch_so_zodiac2_ny_harbor.ff
84989C1BF70F957B06EEB750461154C5  zone\english\patch_sp_berlin.ff
173C215D3815425EC711E6FF1BC67456  zone\english\patch_sp_intro.ff
FD5F72BD0249A57AF13EB0EBBA94842C  zone\english\patch_sp_ny_harbor.ff
990054FA56BD595F071353D0910A5EC4  zone\english\patch_sp_ny_manhattan.ff
7DEA5BD3F74DCC7E165CC418EDFE586F  zone\english\patch_sp_warlord.ff
D1DEDEF92109FDAD7CC150FB09A815EA  zone\english\patch_specialops.ff
CCAC55886DB4A0CED8E36E2EB8D1A7C0  zone\english\patch_survival.ff
A1E4ED255C51E9792586E6CB85AE6A4B  zone\english\payback.ff
68DC2536BD1B717127C6DABE763A2D7B  zone\english\prague.ff
758B01E1DE73229107B8085058F23CB4  zone\english\prague_escape.ff
735499311B73E6E9055DF2E506DC70EC  zone\english\rescue_2.ff
C22D804449439D42C4F654A8CA5F4897  zone\english\so_assassin_payback.ff
E273FEBD0C603916CC0D6A312E63EF04  zone\english\so_assault_rescue_2.ff
0977C725BC29DCA4D58C8BE7AC63BB8D  zone\english\so_deltacamp.ff
848E5CD48A0EEAEAE729E26A72E8C7DD  zone\english\so_heliswitch_berlin.ff
47ECD9D43A2D80F2E6F1175472FCD97F  zone\english\so_ied_berlin.ff
FD86A89CD5323DC2EE6F94B46AB16EC7  zone\english\so_jeep_paris_b.ff
91048BADE29B9F9656527018C3336AA4  zone\english\so_killspree_paris_a.ff
D436E053970C3E9470BEA2D723C0266E  zone\english\so_littlebird_payback.ff
DAF180D8E9AAA6105BA565989BBDA639  zone\english\so_milehigh_hijack.ff
5CE23FE30E87CC59BD636A9CA6B874B9  zone\english\so_nyse_ny_manhattan.ff
2FE3DCDF30FB4BE0BBF7222836C9CF69  zone\english\so_rescue_hijack.ff
91C6605B556186FC63AE0AB4FE60362E  zone\english\so_stealth_prague.ff
38A70A451E3B7331EF962D3A4C394B96  zone\english\so_stealth_warlord.ff
9F36874F9ADB181C502E5C0ACDC61592  zone\english\so_survival_mp_alpha.ff
D63991F7F606FE7446ACF47F5D98B64D  zone\english\so_survival_mp_bootleg.ff
886FF3A2644A9B4AB0F2F619AE8514E7  zone\english\so_survival_mp_bravo.ff
D85B78CDD3A70C60CCBFE259E14434BD  zone\english\so_survival_mp_carbon.ff
514D41B4779E3BC1A7054AA91EE88241  zone\english\so_survival_mp_dome.ff
010EEC7F30EA94760F18A3F64AF0BA66  zone\english\so_survival_mp_exchange.ff
707C189ADF4A1BF614D3DE3A1522310E  zone\english\so_survival_mp_hardhat.ff
F01E13D964582DCFA75EBAF6C2783B00  zone\english\so_survival_mp_interchange.ff
06238711156444E50309B49FC279228E  zone\english\so_survival_mp_lambeth.ff
A408D3C05F5154E28264C03577DE2A8A  zone\english\so_survival_mp_mogadishu.ff
F9D48E2653912210B7DBBC5FAF598A28  zone\english\so_survival_mp_paris.ff
9B85D0CA1A39710F5F7A1A8F79AAD855  zone\english\so_survival_mp_plaza2.ff
995A84753775938BA3AF4817DD5B619F  zone\english\so_survival_mp_radar.ff
C315C9A8DD54BA1855FC05017412F2C9  zone\english\so_survival_mp_seatown.ff
81AF4855BEEBD8FD41416CDEAF2A127B  zone\english\so_survival_mp_underground.ff
3DFAA922A0E2AFFE9FED36EEDB3E6410  zone\english\so_survival_mp_village.ff
719366C9D0425C22507687C3E54C9859  zone\english\so_timetrial_london.ff
FA664D5F6C33B2C43CFC5552683FA430  zone\english\so_trainer2_so_deltacamp.ff
8FA2BF86B7CB2A92FAA429F768C98C2B  zone\english\so_zodiac2_ny_harbor.ff
4A0B0DC3A118C33CB4933EC79697F831  zone\english\sp_berlin.ff
E92D5E3B4C4A5F75329ED937C3C7065B  zone\english\sp_dubai.ff
5593EE1F8551AFD808A8D9D391B0FD7F  zone\english\sp_intro.ff
DC51EAD51B3B59A3557064D48402EA27  zone\english\sp_ny_harbor.ff
676F177E7DB2B982F579BA9E6BF2EA29  zone\english\sp_ny_manhattan.ff
3943F91AE439949D2A7FE49383663818  zone\english\sp_paris_a.ff
0C6EADAB0C4B852E381253695FEEBB2D  zone\english\sp_paris_b.ff
95B2CA64EDCE1A2A117EE583BC948741  zone\english\sp_payback.ff
E2D6C345820E0590801A4AF8B90D1B5A  zone\english\sp_prague.ff
506C055D41E23B35AC838D2879AB83E2  zone\english\sp_warlord.ff
B7D6659ED625C8394EFD16830819BFB5  zone\english\ui.ff
BD0630897873EBBEF1691814BDA56262  zone\english\ui_mp.ff
EDB4A5BF7484BA4136A601DA4CC28750  zone\english\warlord.ff
=== depot_42684
F4654317EDBB42A14004271D6011CF08  localization.txt
7F7A31D43624241EF1767632F779F245  main\localized_spanish_iw00.iwd
3D9A2645AAE7996EED5CB5BDE472A70F  main\localized_spanish_iw01.iwd
B8F26B1B7444473F922B4BBC337D21F6  main\localized_spanish_iw02.iwd
4752701695E051C1E2CC021428143FD6  main\localized_spanish_iw03.iwd
1DDF60FADF54686C3E4854832BA7CDE0  main\localized_spanish_iw04.iwd
B40D97387296E7CA19B97446BC0E96AE  main\localized_spanish_iw05.iwd
E868B3C63111B3CC2986B64A298C44B5  main\video\castle_load.bik
8EC7E21676415F22FEC7FA0DE585A6F9  main\video\hamburg_load.bik
1BED8BA02EBF9C0B1D205ECFF40209AC  main\video\hijack_load.bik
DDB914EB55BB61C79D99169E0D98410D  main\video\legal.bik
E6D17A830430328F6F3B3EACD42A6B84  main\video\london_load.bik
E07453F90C5EA3D7AB30B2735B661134  main\video\paris_ac130_load.bik
8FA65162825DC61E0A22DE40E6490058  main\video\prague_escape_load.bik
5966B1A786BE29D209ABC5590136BB1C  main\video\prologue_select_load.bik
43A7E09F029C0F17EC010ED52FA2D990  main\video\rescue_2_load.bik
9F7A6D7F88A44714933F63AF1C125F87  main\video\sp_berlin_load.bik
52AB1879707C792A40A98C13C205F86A  main\video\sp_dubai_load.bik
4F304B564E3DBEF44580DFF9EBAECADA  main\video\sp_intro_load.bik
A351A89DD3A5B2F7AA968FEFAA6D1CF6  main\video\sp_ny_harbor_load.bik
20A517426DD4B5E20A01A18FF0B08EB2  main\video\sp_ny_manhattan_load.bik
0F92CFDE843F68FC257AD765B87DD8BF  main\video\sp_paris_a_load.bik
BC79ABBEBD308117CE5F38BDE70859FB  main\video\sp_paris_b_load.bik
1377E9F2D784C4498594E996218420EA  main\video\sp_payback_load.bik
4AD3D3B66C443BAB6D7EA7D1EF831A52  main\video\sp_prague_load.bik
C0CECEA19262DC07C504A7720BB6D761  main\video\sp_warlord_load.bik
AA13244B897E06F142E35EB857B2F23B  main\video\startup.bik
981CD7FD205B524729C4287BBE0CCC12  main\video\startup_timeline.bik
287FBFE0722AB6913A1DCAD5C0D7415E  zone\spanish\berlin.ff
346D9695BEAED32FFCB8F61F50770B8C  zone\spanish\castle.ff
71161B25CC1D6D87AD6B0B6632D2B2B7  zone\spanish\code_post_gfx.ff
F99DE016E1B658A37034653572928BBA  zone\spanish\code_post_gfx_mp.ff
54BED7DF67772EF23A5E9B6516D7074E  zone\spanish\code_pre_gfx.ff
1C599A45304F0C0A768ABAC680609992  zone\spanish\code_pre_gfx_mp.ff
0C7D1D6C777F5B0AFA4FDAF684DAF047  zone\spanish\common.ff
78784ABB5391C9D50A7364BC0C9100E4  zone\spanish\common_mp.ff
1101BF9428CFBE35608E8FA00EB730EC  zone\spanish\common_specialops.ff
78C02D7EB785C887A957856D3D6D75D2  zone\spanish\common_survival.ff
1CF00FF679F6F6A82678513EE88BB2A7  zone\spanish\dubai.ff
7C91158EAF91B1855350925F45F49AA5  zone\spanish\hamburg.ff
DD4EA3EFD4553FA627C6CA084D0888E6  zone\spanish\hijack.ff
CDDC7DDD3D6EA772662243AB10A7CFE3  zone\spanish\innocent.ff
479EDA39F6C60B529A544F3955865D7D  zone\spanish\intro.ff
C4401621888780E299F7AFCA6EA1B4B9  zone\spanish\localized_code_post_gfx_mp.ff
8335DB9216A81FDB54EDAA4B7374CC93  zone\spanish\localized_code_pre_gfx_mp.ff
6464CA52ECD8262428C80EB0DB75EF6F  zone\spanish\localized_common_mp.ff
CD17D1CB2FEAD6294A6185B63C4F4CD2  zone\spanish\localized_ui_mp.ff
35232994D79A7BC4397F61457E572E0F  zone\spanish\london.ff
924F77BCD187BD1CBCB0D150B3A64A48  zone\spanish\mp_alpha.ff
E62BD55EE91A68C285CB150056F32D89  zone\spanish\mp_alpha_load.ff
ED9BFC4FAED0597617FE7C64431566FE  zone\spanish\mp_bootleg.ff
3493149A6039BA602105DD69AC95F70B  zone\spanish\mp_bootleg_load.ff
A05C18DB92552BD2BCAE6526405ECC02  zone\spanish\mp_bravo.ff
9777FB3AAF0B9FC0B60C25B023AB4C94  zone\spanish\mp_bravo_load.ff
24E8078702B4C1E53422D9EC4AD84A81  zone\spanish\mp_carbon.ff
A8E93B6211D2B32988D12973524D2B18  zone\spanish\mp_carbon_load.ff
227972F7C04125FB6F3C3C681A1BC972  zone\spanish\mp_dome.ff
4936FDFE7589877FD71F31E9789D4BAB  zone\spanish\mp_dome_load.ff
F323DD8DA2E3BB76C8E9FD4D526B2966  zone\spanish\mp_exchange.ff
5F02FD52A19D879E85F8FC4B8FF83F17  zone\spanish\mp_exchange_load.ff
7BD66C933F57BDBF98691242BC42DF91  zone\spanish\mp_hardhat.ff
239CABA8A4799FCFFC33A73B6C69A391  zone\spanish\mp_hardhat_load.ff
2AD0C193175C066F21245B8E9B8602BC  zone\spanish\mp_interchange.ff
00F25FADCC0FE3B28614142163E64805  zone\spanish\mp_interchange_load.ff
E8D70614AFA15E54AD00BCD7C375FC52  zone\spanish\mp_lambeth.ff
6FCF1BFE900CE16FE58601C277BAF037  zone\spanish\mp_lambeth_load.ff
8726937A43556CDDD0AF3790F578DF84  zone\spanish\mp_mogadishu.ff
710A70169566AD1480146215DC6FB6B6  zone\spanish\mp_mogadishu_load.ff
D6E16967ADB121412CD6E18F6B0222C5  zone\spanish\mp_paris.ff
CC7C65E062FD46FC55916181C462112C  zone\spanish\mp_paris_load.ff
13E93C2C1323C2A8A8732D6EAEB33563  zone\spanish\mp_plaza2.ff
B8550154D4F46583161E88339262052B  zone\spanish\mp_plaza2_load.ff
B7D825082271D312217DB361960A36D2  zone\spanish\mp_radar.ff
EAF23673822DBF63888E849EA0C8889B  zone\spanish\mp_radar_load.ff
2AEF7E85303FEE15874F3E08D70C1EE9  zone\spanish\mp_seatown.ff
BC8A3B5254CDCCD999BC5C04A12680ED  zone\spanish\mp_seatown_load.ff
DAEC31370A7A5F129A1DF388F4B419FA  zone\spanish\mp_underground.ff
9E8AD503A7D16E23312F77E8CF197999  zone\spanish\mp_underground_load.ff
9F66E9F97CD14E03B70882B76B11B032  zone\spanish\mp_village.ff
C78E708C57FB3DF534FFCB9284433EC1  zone\spanish\mp_village_load.ff
C8628DA5FCD4AAE6FEAA1571583E5F94  zone\spanish\ny_harbor.ff
270BEA7AF0D078E0E46D8A8C801CBCFF  zone\spanish\ny_manhattan.ff
5E1AA8C157B6A306A8D6F486198E5E3C  zone\spanish\paris_a.ff
60721FAB47EAD4B45B98D6D1326BC56C  zone\spanish\paris_ac130.ff
717B5490F7D1FDBFF196F7CB4164A4AC  zone\spanish\paris_b.ff
540F05CAC3BA0AF77F4C9274419D50B0  zone\spanish\patch.ff
80D5ED3D122DEC4E4F5D00E6301AA6C1  zone\spanish\patch_hamburg.ff
B4A1F43FE05ACF0A11EF5F03354C9D43  zone\spanish\patch_hijack.ff
90EA386501984CD3978E814549352FE9  zone\spanish\patch_innocent.ff
B0EF23D68DF11BDF12958048EADF3C44  zone\spanish\patch_london.ff
980DEE1B51C2950984B52456DC6F196C  zone\spanish\patch_mp.ff
03B602E1D77E330DD0FC1F5CD23BA225  zone\spanish\patch_mp_dome.ff
FD7049451A602263BE0FF3C1AEC91758  zone\spanish\patch_mp_exchange.ff
4725A9F0BB9923E327AF145FF4D5CAC9  zone\spanish\patch_mp_lambeth.ff
57CB761757DB622263B9D6B25D175D73  zone\spanish\patch_mp_paris.ff
AFCFF3A9CB57BD7981DE98136A6A2ABF  zone\spanish\patch_mp_radar.ff
7B603AD55BEBD3FA8D85263E1111318A  zone\spanish\patch_mp_underground.ff
067ACAFAFC0022EAF7288282969B8794  zone\spanish\patch_mp_village.ff
3E5D4DA4C9F816E63C2749B947739EBA  zone\spanish\patch_paris_ac130.ff
7ADF10EE94C9E120FF804B4A0ACCE876  zone\spanish\patch_prague_escape.ff
F2D7F7BD6C15703155830CE59C4FD276  zone\spanish\patch_so_ied_berlin.ff
99A278411D8076B148061806F4D5BFA0  zone\spanish\patch_so_littlebird_payback.ff
1AAC25317792CA0E738FEC3E9D524109  zone\spanish\patch_so_survival_mp_village.ff
95E62720F7E1715497D4514CA22C0F7C  zone\spanish\patch_so_zodiac2_ny_harbor.ff
DF74BCDBDC60F7FF6074906BA7C4452F  zone\spanish\patch_sp_berlin.ff
8B15E166FBED60A10FF52CEDE9680E9A  zone\spanish\patch_sp_intro.ff
549630A09422C02CCADE92C7F8CCB660  zone\spanish\patch_sp_ny_harbor.ff
20755460B1BA3A3314FFB374A4F31BD8  zone\spanish\patch_sp_ny_manhattan.ff
7DEA5BD3F74DCC7E165CC418EDFE586F  zone\spanish\patch_sp_warlord.ff
7A4E1DBDE27F74C6CC6CA6FE8F24EC20  zone\spanish\patch_specialops.ff
E4145DB0FF25C23DE31AFD128F46DA8C  zone\spanish\patch_survival.ff
DE1D60325A0FE3F396B7E23C074110AC  zone\spanish\payback.ff
3E0C785D7387560BC98655454C1D2F94  zone\spanish\prague.ff
F1DA04231A416607A989886883C713DD  zone\spanish\prague_escape.ff
4D22BFED6B098918B3844270168AE256  zone\spanish\rescue_2.ff
471D264F1E7575D84F028648424FCC0F  zone\spanish\so_assassin_payback.ff
BFF2609602A6FBA15851A62BD4A6E22C  zone\spanish\so_assault_rescue_2.ff
677D2BE8398BE25F38F4BB60E725BFB9  zone\spanish\so_deltacamp.ff
C021B0D52E253C5942B8F8357390A39F  zone\spanish\so_heliswitch_berlin.ff
33375AADA645DF4CD57E336A60416B61  zone\spanish\so_ied_berlin.ff
B30E013A1835AD854AFB35D2807065C1  zone\spanish\so_jeep_paris_b.ff
D19B2BA9D18FA8FBDCA1BED452590852  zone\spanish\so_killspree_paris_a.ff
0B309C3D39FA9CE22641D945E39AD1C9  zone\spanish\so_littlebird_payback.ff
D68ABBA363E257E2E416FA51CF3FD1CF  zone\spanish\so_milehigh_hijack.ff
544447AD4E1DE70838A3639927AF2181  zone\spanish\so_nyse_ny_manhattan.ff
EE2C17DD9B5641BA41E030B2B84304E8  zone\spanish\so_rescue_hijack.ff
7FBCB8A498989E7715EB086F1FC19D13  zone\spanish\so_stealth_prague.ff
ED3928D1E2B000E53AF13CBB00641808  zone\spanish\so_stealth_warlord.ff
8711E231D9A9F9034401C29821829D86  zone\spanish\so_survival_mp_alpha.ff
4983263468CEA6B4B8DB16305B102214  zone\spanish\so_survival_mp_bootleg.ff
B894153D547D4375A7233933F65BF490  zone\spanish\so_survival_mp_bravo.ff
A9296E40BCC623DC5B18220720E13675  zone\spanish\so_survival_mp_carbon.ff
F2C189E01B838E45CFB6C7B48288C3A4  zone\spanish\so_survival_mp_dome.ff
B30C37DE4E6AE7CF59A49C419D4CD645  zone\spanish\so_survival_mp_exchange.ff
A92DBC78DB384A945B936CE9A1D8D414  zone\spanish\so_survival_mp_hardhat.ff
A411A5C1734D4DD9AD03C91729D8D23F  zone\spanish\so_survival_mp_interchange.ff
23D0604EDAAB778C5D943983DE74F8CD  zone\spanish\so_survival_mp_lambeth.ff
7E7F8D79E035B915454DFF6BD546B19D  zone\spanish\so_survival_mp_mogadishu.ff
CF8A461EE99E520D974278154F2ADF03  zone\spanish\so_survival_mp_paris.ff
A95B44A44CBBDAFCF782F38AB82A40FD  zone\spanish\so_survival_mp_plaza2.ff
3FBCA3656AB834C4614DDC2650E0975A  zone\spanish\so_survival_mp_radar.ff
9BFBC8B4DB623B2DB6711EA6FE85E8F8  zone\spanish\so_survival_mp_seatown.ff
BB681C56E6E9FBE1F330031A9976FBC5  zone\spanish\so_survival_mp_underground.ff
D26C9F300FBC67CB27402C7FD2897FC8  zone\spanish\so_survival_mp_village.ff
BFD3AA3026474A72117FB8B96DEF8C0E  zone\spanish\so_timetrial_london.ff
CDED318AAD7C62B1DB6DA73FDB9A59B5  zone\spanish\so_trainer2_so_deltacamp.ff
D1600AA337A0909F8BE0F9E96F1D1371  zone\spanish\so_zodiac2_ny_harbor.ff
3E8C28A681F934F74FEABD921BE22922  zone\spanish\sp_berlin.ff
F0B7B30F61F1DD45EE3D26C9C2679352  zone\spanish\sp_dubai.ff
05A9969061E7FD486655B8EEA68A97D6  zone\spanish\sp_intro.ff
00247D6F00913B725EE9927FE8804E57  zone\spanish\sp_ny_harbor.ff
3210C67A0776F676C9D2F9670EC4B43E  zone\spanish\sp_ny_manhattan.ff
18895BB9710B5E4DB321C4945250D204  zone\spanish\sp_paris_a.ff
89D34AECEA6A42B6D8F3C264FF311D9B  zone\spanish\sp_paris_b.ff
AB4A99678F3A2DD5F39B364931CFC5A7  zone\spanish\sp_payback.ff
41DD047284F61F2844E6D9DEDCBE6163  zone\spanish\sp_prague.ff
78FB0E3DB211CFC855B4DC93E59D6C85  zone\spanish\sp_warlord.ff
AA6EB0710F3DCD3FF76B226404A7CA05  zone\spanish\ui.ff
BD0630897873EBBEF1691814BDA56262  zone\spanish\ui_mp.ff
C948B575B4429AA87DB9C37D270748D4  zone\spanish\warlord.ff
=== depot_42685
69EDA6B4ACB1292BC911024E1978A278  localization.txt
9D0AB5EB808A68F738DFCF346BAF048F  main\localized_german_iw00.iwd
3A197D0D24F24DF6122D94E01520C03D  main\localized_german_iw01.iwd
7D68AD33BF58B09901FF75923CE67A51  main\localized_german_iw02.iwd
28B35ACF0F3DA855CD893DA5817D5B47  main\localized_german_iw03.iwd
04BEF125C48154B5DB0F593E0EC40F04  main\localized_german_iw04.iwd
88574D1BD267F28BA891F77A05700B56  main\localized_german_iw05.iwd
28C6007B92D3EE01C544AE6C6FFD411D  main\video\castle_load.bik
ADABF0EF8CE0BFA1D5250A8924564188  main\video\hamburg_load.bik
96F5444AD4A7E2DAD72295134F413423  main\video\hijack_load.bik
4DCE1AAD69BFB1F869881046F2423594  main\video\legal.bik
658383CC9CA487D60C3FF723F1E9F414  main\video\london_load.bik
404F42018B0FAE8284EF0490F051A743  main\video\paris_ac130_load.bik
08F921E7977197039649661038AB42D9  main\video\prague_escape_load.bik
72C4E659B3FB789FE314FB2017542D3E  main\video\prologue_select_load.bik
006F670FF7EAEC3A91F8A671FA35622D  main\video\rescue_2_load.bik
B7D7CFEE42EE0584CBCD0CE8E021B97E  main\video\sp_berlin_load.bik
7968C2A504B771DB0725C9506BFCD14D  main\video\sp_dubai_load.bik
374C05C5C0785071780ED373B4CBAC08  main\video\sp_intro_load.bik
38D86B9068AF58082B6687C0F0135955  main\video\sp_ny_harbor_load.bik
C1C687FBACF4FDBB7639B3C7349F3708  main\video\sp_ny_manhattan_load.bik
EEE23C0942B78EDE2B820718835DF4E9  main\video\sp_paris_a_load.bik
31D3D34B88F99BF2BD225418D29442B6  main\video\sp_paris_b_load.bik
22EBEE6317C2508EF7B9D8B3E33A423C  main\video\sp_payback_load.bik
4ADF6D54FCD0EFE00E2B4A07BF0558EA  main\video\sp_prague_load.bik
9C2710658486EFC986713F7A77E4E1E0  main\video\sp_warlord_load.bik
1031EFE088A87A2B06A8F933F638B27C  main\video\startup.bik
59931FF3BA94A876DAE800B81C78AF77  main\video\startup_timeline.bik
52CED7D86777B923F3CDC34D4AB0B1B2  zone\german\berlin.ff
805BE9FD162F245B130D0CF127836BC9  zone\german\castle.ff
24FA3F18ADD443A89815DDDD260D6BA8  zone\german\code_post_gfx.ff
F99DE016E1B658A37034653572928BBA  zone\german\code_post_gfx_mp.ff
54BED7DF67772EF23A5E9B6516D7074E  zone\german\code_pre_gfx.ff
1C599A45304F0C0A768ABAC680609992  zone\german\code_pre_gfx_mp.ff
857D7E7A914694DB0299A0E4562F9013  zone\german\common.ff
78784ABB5391C9D50A7364BC0C9100E4  zone\german\common_mp.ff
4605AD7A9C228988AADC74248823548F  zone\german\common_specialops.ff
3843946BB6795287262B15AE6A6AA959  zone\german\common_survival.ff
430C1D75A1593DADA3930061B6B53A94  zone\german\dubai.ff
B488E75EE3C338D90A736A56E9738DA3  zone\german\hamburg.ff
F31B75E59683414ABD43105A117E8AF8  zone\german\hijack.ff
387E78D813C6034E3739D447DA8C6124  zone\german\innocent.ff
4229ACCD654178041CEE07B5AB2C39AD  zone\german\intro.ff
7249E02CA08A6E09D27467BED7E06731  zone\german\localized_code_post_gfx_mp.ff
27C1E1DAFE96297EB8BF6BC11399198F  zone\german\localized_code_pre_gfx_mp.ff
E6C72AF7917B58CE6B6D3DE8C63177C8  zone\german\localized_common_mp.ff
BD5940F0FBCD26477BC5E172E5132129  zone\german\localized_ui_mp.ff
7C89007516C588D1C92D78D97D693EDB  zone\german\london.ff
924F77BCD187BD1CBCB0D150B3A64A48  zone\german\mp_alpha.ff
E62BD55EE91A68C285CB150056F32D89  zone\german\mp_alpha_load.ff
ED9BFC4FAED0597617FE7C64431566FE  zone\german\mp_bootleg.ff
3493149A6039BA602105DD69AC95F70B  zone\german\mp_bootleg_load.ff
A05C18DB92552BD2BCAE6526405ECC02  zone\german\mp_bravo.ff
9777FB3AAF0B9FC0B60C25B023AB4C94  zone\german\mp_bravo_load.ff
24E8078702B4C1E53422D9EC4AD84A81  zone\german\mp_carbon.ff
A8E93B6211D2B32988D12973524D2B18  zone\german\mp_carbon_load.ff
227972F7C04125FB6F3C3C681A1BC972  zone\german\mp_dome.ff
4936FDFE7589877FD71F31E9789D4BAB  zone\german\mp_dome_load.ff
F323DD8DA2E3BB76C8E9FD4D526B2966  zone\german\mp_exchange.ff
5F02FD52A19D879E85F8FC4B8FF83F17  zone\german\mp_exchange_load.ff
7BD66C933F57BDBF98691242BC42DF91  zone\german\mp_hardhat.ff
239CABA8A4799FCFFC33A73B6C69A391  zone\german\mp_hardhat_load.ff
2AD0C193175C066F21245B8E9B8602BC  zone\german\mp_interchange.ff
00F25FADCC0FE3B28614142163E64805  zone\german\mp_interchange_load.ff
E8D70614AFA15E54AD00BCD7C375FC52  zone\german\mp_lambeth.ff
6FCF1BFE900CE16FE58601C277BAF037  zone\german\mp_lambeth_load.ff
8726937A43556CDDD0AF3790F578DF84  zone\german\mp_mogadishu.ff
710A70169566AD1480146215DC6FB6B6  zone\german\mp_mogadishu_load.ff
D6E16967ADB121412CD6E18F6B0222C5  zone\german\mp_paris.ff
CC7C65E062FD46FC55916181C462112C  zone\german\mp_paris_load.ff
13E93C2C1323C2A8A8732D6EAEB33563  zone\german\mp_plaza2.ff
B8550154D4F46583161E88339262052B  zone\german\mp_plaza2_load.ff
B7D825082271D312217DB361960A36D2  zone\german\mp_radar.ff
EAF23673822DBF63888E849EA0C8889B  zone\german\mp_radar_load.ff
2AEF7E85303FEE15874F3E08D70C1EE9  zone\german\mp_seatown.ff
BC8A3B5254CDCCD999BC5C04A12680ED  zone\german\mp_seatown_load.ff
DAEC31370A7A5F129A1DF388F4B419FA  zone\german\mp_underground.ff
9E8AD503A7D16E23312F77E8CF197999  zone\german\mp_underground_load.ff
9F66E9F97CD14E03B70882B76B11B032  zone\german\mp_village.ff
C78E708C57FB3DF534FFCB9284433EC1  zone\german\mp_village_load.ff
7C203D27D2077C06EC475690821BC196  zone\german\ny_harbor.ff
8D05B80E8C4585FE46C0FEDD6659146C  zone\german\ny_manhattan.ff
E96A929E0423CC1A5507E0ABE8C72BFC  zone\german\paris_a.ff
145F0003E9CAD40C331DD55BE1CCA5AA  zone\german\paris_ac130.ff
7E45F58C5264A9121AEA6609EEB5D05F  zone\german\paris_b.ff
A4EA1C18739A066146EED617A69D7F0F  zone\german\patch.ff
79FB84960699D0CAB076BA7CAD878691  zone\german\patch_hamburg.ff
CD406A3DB179F160EAE73953DD953FF6  zone\german\patch_hijack.ff
A6083A17ABE3EDA1960FB49424100074  zone\german\patch_innocent.ff
121EEC97CB4BD6BB7889E4264726DE5E  zone\german\patch_london.ff
C03E9E3B958219ED2777E04E3385E6EF  zone\german\patch_mp.ff
821D698AB96063F46CE10CAB168EC48A  zone\german\patch_mp_dome.ff
DFA1D501197ADA891F540F0C2494FDB9  zone\german\patch_mp_exchange.ff
3B7BEF6A14D6AC52482061B301C2D05A  zone\german\patch_mp_lambeth.ff
7395D6F3EE595B81B36143F77BE1D424  zone\german\patch_mp_paris.ff
487912EE94B51A738FC1274F3CB42468  zone\german\patch_mp_radar.ff
71A6BA0ACDA5F99D737A0AE16D00CB05  zone\german\patch_mp_underground.ff
89AEA511DE3481A9F9B20D4AF24E3E84  zone\german\patch_mp_village.ff
96E2E607566BCA008B9CC9C71E4452F9  zone\german\patch_paris_ac130.ff
EAE4139AC1AD98FF6D11214D39CA00E6  zone\german\patch_prague_escape.ff
F2D7F7BD6C15703155830CE59C4FD276  zone\german\patch_so_ied_berlin.ff
9633BEACF7A1289C7E25F37A731B8F08  zone\german\patch_so_littlebird_payback.ff
1AAC25317792CA0E738FEC3E9D524109  zone\german\patch_so_survival_mp_village.ff
C482F9A5F3BAC6685A74BADDA69B8858  zone\german\patch_so_zodiac2_ny_harbor.ff
84989C1BF70F957B06EEB750461154C5  zone\german\patch_sp_berlin.ff
28CB1E33776671D63A9AF0582FFABA2E  zone\german\patch_sp_intro.ff
8AD74362A699F5CA192D3D9782651B08  zone\german\patch_sp_ny_harbor.ff
990054FA56BD595F071353D0910A5EC4  zone\german\patch_sp_ny_manhattan.ff
7DEA5BD3F74DCC7E165CC418EDFE586F  zone\german\patch_sp_warlord.ff
9FB85A61D1ECA355885C9876020B8A78  zone\german\patch_specialops.ff
BF9D180ECEDC634E56E854D664CCDC51  zone\german\patch_survival.ff
1D5BB3EBF4FDBAACB38D754C2CA611A6  zone\german\payback.ff
638049ECBB02BAFDBC334B89A3E3C51F  zone\german\prague.ff
8658C2D0F935F1EEADAE3226AF007AFB  zone\german\prague_escape.ff
A0450D4EE4293C6FD7B07A2FEFBAFB97  zone\german\rescue_2.ff
922978BE30B30EE8C6754DFFE832438D  zone\german\so_assassin_payback.ff
8E301F62F4DF23B5B583A250E7FB1A18  zone\german\so_assault_rescue_2.ff
69E0F788BAD2139AA44B608141432846  zone\german\so_deltacamp.ff
0CE92BE797971A7A01AA239113A5E133  zone\german\so_heliswitch_berlin.ff
3A7146001B9D24FD0F83C85472339D33  zone\german\so_ied_berlin.ff
173357D3FB0141A79E8BF416F38F607A  zone\german\so_jeep_paris_b.ff
1FC74D5CD2A7907F282DB26FADE3475A  zone\german\so_killspree_paris_a.ff
60C3B6B2D567053DD1C063B645F4C875  zone\german\so_littlebird_payback.ff
C398964C16A41D19D6B829157EDACE25  zone\german\so_milehigh_hijack.ff
6B546A311DA0E820D891CCE4E9F600B9  zone\german\so_nyse_ny_manhattan.ff
2A378EB868EB560031EB0A4C7BCC67D7  zone\german\so_rescue_hijack.ff
F288ED1A352E786778C1409613C17060  zone\german\so_stealth_prague.ff
B3657986E4CCBB1BD30D3264F9F998B9  zone\german\so_stealth_warlord.ff
8711E231D9A9F9034401C29821829D86  zone\german\so_survival_mp_alpha.ff
9E27DB327B6DA265C44F36C25403A040  zone\german\so_survival_mp_bootleg.ff
88C4EFD4103ED97EC76F968BF3B7388A  zone\german\so_survival_mp_bravo.ff
CE336DB4609C1D9990C75238152E64D1  zone\german\so_survival_mp_carbon.ff
A041BA6F7F73CA0458F9745F1277A3A3  zone\german\so_survival_mp_dome.ff
B5191A2BCD59B707C9B1835F95F8F81C  zone\german\so_survival_mp_exchange.ff
68F0031E266EAB5AB3F7A138BEEE74FB  zone\german\so_survival_mp_hardhat.ff
630966C931D09C7903210CB74BFD1804  zone\german\so_survival_mp_interchange.ff
23D0604EDAAB778C5D943983DE74F8CD  zone\german\so_survival_mp_lambeth.ff
402CC914CE308C63F8DE5BF88742580F  zone\german\so_survival_mp_mogadishu.ff
BA5C995E1FD5BF8D9BAD33E83F81E60B  zone\german\so_survival_mp_paris.ff
A95B44A44CBBDAFCF782F38AB82A40FD  zone\german\so_survival_mp_plaza2.ff
4DE7F2A018343389983F772678FBCC1A  zone\german\so_survival_mp_radar.ff
400D07BFE43D56644E83C636E624EBB0  zone\german\so_survival_mp_seatown.ff
BB681C56E6E9FBE1F330031A9976FBC5  zone\german\so_survival_mp_underground.ff
DF9773166D7189A249C48150D03F548D  zone\german\so_survival_mp_village.ff
43C7B910A9CB57362A989F7A8E49B8BB  zone\german\so_timetrial_london.ff
C21F62EC73296C126D85BE70E8A1F2F3  zone\german\so_trainer2_so_deltacamp.ff
02E921890B11A087ABD41137F52AADFA  zone\german\so_zodiac2_ny_harbor.ff
60A60844BD5DCD20D4F95BD2D660D9BF  zone\german\sp_berlin.ff
35A06843F09C42029A254C7AE4D21B0B  zone\german\sp_dubai.ff
E1CDEF0E9EE650E35195E9181343C8F8  zone\german\sp_intro.ff
FC4E4724A63A18E34B9D2B267BB455BD  zone\german\sp_ny_harbor.ff
D8630554310B071BB37BD0A2F74AC68C  zone\german\sp_ny_manhattan.ff
E85F4C70FBCC15E9E217B9B40D141553  zone\german\sp_paris_a.ff
4F906C4D3DEF6B0C7918F68517A6F78B  zone\german\sp_paris_b.ff
E92B3239D0B6A9C5F4B8FBB1A79434FD  zone\german\sp_payback.ff
EBEE40C1B58B505E66F8D31E8523196C  zone\german\sp_prague.ff
5D3A0090969D80A7D26A38A1286AC391  zone\german\sp_warlord.ff
ED011DC7F3AD15A9590304E23A9214F2  zone\german\ui.ff
BD0630897873EBBEF1691814BDA56262  zone\german\ui_mp.ff
3F06509AC4EAAA6AFEB5EA8217E8DF63  zone\german\warlord.ff
=== depot_42686
579B7D4F7BB97AA97D44335D68106F79  localization.txt
8AD9E0379DAAA061F54A4F1681FBE915  main\localized_french_iw00.iwd
B8E49376B516708A64DF78D27363E6C9  main\localized_french_iw01.iwd
E7E63692683AB396FEBA988387FDC7A1  main\localized_french_iw02.iwd
1AC76A8C0B5EF82D9F84BF5CF19CC158  main\localized_french_iw03.iwd
4937F89ACEA9B76070AF969C2DA72C29  main\localized_french_iw04.iwd
753897A118059426B11D2AF787130CBB  main\localized_french_iw05.iwd
044B00F56AA24BC2D525765C604CC516  main\video\castle_load.bik
BC4D8B0D60FF68F1EB7F896504CB8FC8  main\video\hamburg_load.bik
3527B99908D57A7745A54BAEE548CEFD  main\video\hijack_load.bik
446FA8E068DD32668EC9635AAE964375  main\video\legal.bik
A67FCD1E15A6FB3B44B649B1C102995C  main\video\london_load.bik
1CA9341A3663D92AAF00A9215545A6CA  main\video\paris_ac130_load.bik
1501033EA3BD3ECE4E8D6848813560AD  main\video\prague_escape_load.bik
15457E0906307EF4FDC5B5D744A00C8D  main\video\prologue_select_load.bik
AB37DC2DFB070885C3FD464AC74B359E  main\video\rescue_2_load.bik
C757E23C2B7F514400231B2F59601739  main\video\sp_berlin_load.bik
A05CDB1201F5F0A307FEA0CF93D82724  main\video\sp_dubai_load.bik
0B90821960BB4925B12A55856D4273DE  main\video\sp_intro_load.bik
28BD691A60697366812C15726013B822  main\video\sp_ny_harbor_load.bik
F1F7747FD2537D046BE58A9812AF6B6E  main\video\sp_ny_manhattan_load.bik
1A742AE47F0BB728CB515A31D146C5D0  main\video\sp_paris_a_load.bik
F3DF9BD60A7D51EF3BE0C0D186B33DD6  main\video\sp_paris_b_load.bik
AD58B27DCADCC908E4BC711B9617E067  main\video\sp_payback_load.bik
C87A6EDEB81DDE2FA45AB610B2449772  main\video\sp_prague_load.bik
3E5384C50B302A4103991BE6C103EF96  main\video\sp_warlord_load.bik
12E4143A72AD6C95220C845BDC150E41  main\video\startup.bik
4C05FB2FF11276E2FF328A88D271608E  main\video\startup_timeline.bik
344BC69369901A3EFBFB5D19E4BAF927  zone\french\berlin.ff
4559CAAD1CBE51E9669373E97C71E716  zone\french\castle.ff
7CEDBA3F2BFA71EB9FC95F5F7A4E5655  zone\french\code_post_gfx.ff
F99DE016E1B658A37034653572928BBA  zone\french\code_post_gfx_mp.ff
4CA6456C0B6BC92E1207F22F68AA0A71  zone\french\code_pre_gfx.ff
1C599A45304F0C0A768ABAC680609992  zone\french\code_pre_gfx_mp.ff
A3EFADB463013737E80394CBC63F5E48  zone\french\common.ff
78784ABB5391C9D50A7364BC0C9100E4  zone\french\common_mp.ff
91F5E94ED74E9453808CCDE311D9B967  zone\french\common_specialops.ff
D87E1027A52D8D33D9EDC30B7462598D  zone\french\common_survival.ff
63FE12C021F315476404417902FE4B2B  zone\french\dubai.ff
F88BF53610F422D4B6C5AD4AFF53DB7E  zone\french\hamburg.ff
0948514BA5A5749AA898363AB01C8C31  zone\french\hijack.ff
A4E2E0D7F204BECA831856834BB88D7F  zone\french\innocent.ff
D8E8BE9D7239C52D194FCA0BED538765  zone\french\intro.ff
4CF00CB8CD7E160A5CB5D4CBAA63215E  zone\french\localized_code_post_gfx_mp.ff
FF17F89E2747ACCDF12B33C429312D60  zone\french\localized_code_pre_gfx_mp.ff
DEADA8F4C2537D14081735A7C490526D  zone\french\localized_common_mp.ff
27F0D121F6BE7C8C4ED786CE19801988  zone\french\localized_ui_mp.ff
97C9EAAB9B6FA7AE0DC1A9E4EBCB023F  zone\french\london.ff
924F77BCD187BD1CBCB0D150B3A64A48  zone\french\mp_alpha.ff
E62BD55EE91A68C285CB150056F32D89  zone\french\mp_alpha_load.ff
ED9BFC4FAED0597617FE7C64431566FE  zone\french\mp_bootleg.ff
3493149A6039BA602105DD69AC95F70B  zone\french\mp_bootleg_load.ff
A05C18DB92552BD2BCAE6526405ECC02  zone\french\mp_bravo.ff
9777FB3AAF0B9FC0B60C25B023AB4C94  zone\french\mp_bravo_load.ff
24E8078702B4C1E53422D9EC4AD84A81  zone\french\mp_carbon.ff
A8E93B6211D2B32988D12973524D2B18  zone\french\mp_carbon_load.ff
227972F7C04125FB6F3C3C681A1BC972  zone\french\mp_dome.ff
4936FDFE7589877FD71F31E9789D4BAB  zone\french\mp_dome_load.ff
F323DD8DA2E3BB76C8E9FD4D526B2966  zone\french\mp_exchange.ff
5F02FD52A19D879E85F8FC4B8FF83F17  zone\french\mp_exchange_load.ff
7BD66C933F57BDBF98691242BC42DF91  zone\french\mp_hardhat.ff
239CABA8A4799FCFFC33A73B6C69A391  zone\french\mp_hardhat_load.ff
2AD0C193175C066F21245B8E9B8602BC  zone\french\mp_interchange.ff
00F25FADCC0FE3B28614142163E64805  zone\french\mp_interchange_load.ff
E8D70614AFA15E54AD00BCD7C375FC52  zone\french\mp_lambeth.ff
6FCF1BFE900CE16FE58601C277BAF037  zone\french\mp_lambeth_load.ff
8726937A43556CDDD0AF3790F578DF84  zone\french\mp_mogadishu.ff
710A70169566AD1480146215DC6FB6B6  zone\french\mp_mogadishu_load.ff
D6E16967ADB121412CD6E18F6B0222C5  zone\french\mp_paris.ff
CC7C65E062FD46FC55916181C462112C  zone\french\mp_paris_load.ff
13E93C2C1323C2A8A8732D6EAEB33563  zone\french\mp_plaza2.ff
B8550154D4F46583161E88339262052B  zone\french\mp_plaza2_load.ff
B7D825082271D312217DB361960A36D2  zone\french\mp_radar.ff
EAF23673822DBF63888E849EA0C8889B  zone\french\mp_radar_load.ff
2AEF7E85303FEE15874F3E08D70C1EE9  zone\french\mp_seatown.ff
BC8A3B5254CDCCD999BC5C04A12680ED  zone\french\mp_seatown_load.ff
DAEC31370A7A5F129A1DF388F4B419FA  zone\french\mp_underground.ff
9E8AD503A7D16E23312F77E8CF197999  zone\french\mp_underground_load.ff
9F66E9F97CD14E03B70882B76B11B032  zone\french\mp_village.ff
C78E708C57FB3DF534FFCB9284433EC1  zone\french\mp_village_load.ff
0CE2857CFC45E40C400AE72BF587784E  zone\french\ny_harbor.ff
8E562C2C7C0C09910AE6D36848BF50AD  zone\french\ny_manhattan.ff
23CE5570145ECA22538B7CD13A2F7729  zone\french\paris_a.ff
5788F86D5575BAC31B201E4F8EDAB8FF  zone\french\paris_ac130.ff
20D410DCC0BD691A06304601D4322736  zone\french\paris_b.ff
B0FD7A238398EED6B7ABF313A6A6239B  zone\french\patch.ff
329F83588B648B931E927CB019412374  zone\french\patch_hamburg.ff
B4A1F43FE05ACF0A11EF5F03354C9D43  zone\french\patch_hijack.ff
7F4322F08DE24708A5520DDDEB96948D  zone\french\patch_innocent.ff
EB618D4EF0D344A61BEB0D691450C039  zone\french\patch_london.ff
1908F01609F844B6E2129536F02018B6  zone\french\patch_mp.ff
85CCDA8F72ADEEF756BD8570B68906B0  zone\french\patch_mp_dome.ff
F695AB8C6489DEB05DE04BDBCB2318BE  zone\french\patch_mp_exchange.ff
7B4EEE61B217BE9E354508D28E894267  zone\french\patch_mp_lambeth.ff
5FDB17A9878F343A68D7C3FEE4A9DBCF  zone\french\patch_mp_paris.ff
2CF23F85EA3AC8B8F393839BE6FD9BBA  zone\french\patch_mp_radar.ff
3A6E88418B30D31B06DF521E1C30B900  zone\french\patch_mp_underground.ff
4D0BBB384A726905A4CDC2E302DB542E  zone\french\patch_mp_village.ff
96E2E607566BCA008B9CC9C71E4452F9  zone\french\patch_paris_ac130.ff
F3458D1B0584445876F63DF63DC8C73E  zone\french\patch_prague_escape.ff
13BE40323E991B96EB4A2FEEAEBA9B6E  zone\french\patch_so_ied_berlin.ff
8B18E64B6B58606976001AE97AAEC446  zone\french\patch_so_littlebird_payback.ff
A192E4E028CE8403CC3A909B40FCA998  zone\french\patch_so_survival_mp_village.ff
2FC86B8C19E5F36A09F3335F6A060E4D  zone\french\patch_so_zodiac2_ny_harbor.ff
DF74BCDBDC60F7FF6074906BA7C4452F  zone\french\patch_sp_berlin.ff
DDCA7CB5C3BA306A91AF056B3834D59F  zone\french\patch_sp_intro.ff
EB5BE3FC4954C64E8D3EECC310F520E9  zone\french\patch_sp_ny_harbor.ff
20755460B1BA3A3314FFB374A4F31BD8  zone\french\patch_sp_ny_manhattan.ff
7DEA5BD3F74DCC7E165CC418EDFE586F  zone\french\patch_sp_warlord.ff
7BE163CDCAEF5AD41BBBE95A096C9631  zone\french\patch_specialops.ff
300B89B714D9143B1B757E18B4B585BE  zone\french\patch_survival.ff
D04C7F649EBFA4E9B5A00D5030CA0CB7  zone\french\payback.ff
1DC98ED643A656CE95C31D07286442B4  zone\french\prague.ff
71A2DC0CECB5B9919E24C79F5F67C0E6  zone\french\prague_escape.ff
BEC7E93361E8BB181CBCF5E21AAB30F2  zone\french\rescue_2.ff
435AC200A6A085186750EFB4D929331A  zone\french\so_assassin_payback.ff
BF7FEE5D996B7CB8A14BBBE7F4E96C81  zone\french\so_assault_rescue_2.ff
95D6C614A92C575C60715D779C8DD86D  zone\french\so_deltacamp.ff
289A96FD0FE5A287CC9E2CD04EB6B0B3  zone\french\so_heliswitch_berlin.ff
23897BFA7982DCAF210060FCA5C8D8C0  zone\french\so_ied_berlin.ff
CA2D955AA30E8116810D4E7D4D961CE1  zone\french\so_jeep_paris_b.ff
D771664F65E062A1F173198F1119AE6D  zone\french\so_killspree_paris_a.ff
0009AFA25AB58B00B61A985B40E61309  zone\french\so_littlebird_payback.ff
9CCC75602FD065FC1DB7109AD8D824BD  zone\french\so_milehigh_hijack.ff
ACF16D501826048552FEF42925BCFD51  zone\french\so_nyse_ny_manhattan.ff
E7D2C6A61795DB8838B189B7D470610E  zone\french\so_rescue_hijack.ff
4C5047899576D935B84326BAAC59D0B4  zone\french\so_stealth_prague.ff
1F40EDE16B8EC845DC494673CC1E8BAF  zone\french\so_stealth_warlord.ff
8711E231D9A9F9034401C29821829D86  zone\french\so_survival_mp_alpha.ff
9E58DD413E028127AB1D581419E13048  zone\french\so_survival_mp_bootleg.ff
B894153D547D4375A7233933F65BF490  zone\french\so_survival_mp_bravo.ff
A9296E40BCC623DC5B18220720E13675  zone\french\so_survival_mp_carbon.ff
185B3DEA3B79D1329C40C66A80AE48E6  zone\french\so_survival_mp_dome.ff
12C64486147952A0AA264F57E0219EC8  zone\french\so_survival_mp_exchange.ff
A92DBC78DB384A945B936CE9A1D8D414  zone\french\so_survival_mp_hardhat.ff
A411A5C1734D4DD9AD03C91729D8D23F  zone\french\so_survival_mp_interchange.ff
F2D7201142792AAA863550FC991F1A16  zone\french\so_survival_mp_lambeth.ff
6D7385C48532825E4413334DC17603B4  zone\french\so_survival_mp_mogadishu.ff
5AF81F11C210AC473F788D1AD0ABBB3E  zone\french\so_survival_mp_paris.ff
69BCA19ADC26963D77D55BB5E027E9AB  zone\french\so_survival_mp_plaza2.ff
A0515761C6ED105216215467F3416705  zone\french\so_survival_mp_radar.ff
400D07BFE43D56644E83C636E624EBB0  zone\french\so_survival_mp_seatown.ff
BB681C56E6E9FBE1F330031A9976FBC5  zone\french\so_survival_mp_underground.ff
C5884576569215E37F7288E97974897B  zone\french\so_survival_mp_village.ff
4EEFE0EEFD283975F802D83D71AF70CA  zone\french\so_timetrial_london.ff
1D4AD961767E0BE29B2D6EFE36C0520E  zone\french\so_trainer2_so_deltacamp.ff
5BC5B67D212EBCD3C23B2BFE1E993CAF  zone\french\so_zodiac2_ny_harbor.ff
658353241EEC9147D3FF8C380C0930F7  zone\french\sp_berlin.ff
0C87F3D2131C19AB96D0F2D9FB4A2930  zone\french\sp_dubai.ff
6F2E91EA70A54B5D707019E6C5A04971  zone\french\sp_intro.ff
F2271E63CE47FE633B80068DAABC3DF8  zone\french\sp_ny_harbor.ff
9F054835B65E9B8AFBF5B4A07249CE2B  zone\french\sp_ny_manhattan.ff
8AC522A6779981FFAE170B19856D1DAD  zone\french\sp_paris_a.ff
5D30E5FFE1F37922784BCCCFDA9FFC35  zone\french\sp_paris_b.ff
64EFE488B1DCD9C1E277D51EC0277F13  zone\french\sp_payback.ff
98A265D92837BACD77254C18D56FCE5E  zone\french\sp_prague.ff
F0076C29A3CEA71CB94B1C369771CCCA  zone\french\sp_warlord.ff
61FCE6639F4094EB047F34779C890390  zone\french\ui.ff
BD0630897873EBBEF1691814BDA56262  zone\french\ui_mp.ff
F9A286879E3D6A0A8E229DAB631B182D  zone\french\warlord.ff
=== depot_42687
89A9E317FD9E5ADDA3B4A4BAD58FC66F  localization.txt
DBBDD41704A68B6B50495D287B94D330  main\localized_italian_iw00.iwd
F0C04AA3169485CDE02D10AADD4F8C11  main\localized_italian_iw01.iwd
248F673B05C29DCB83B6AAEA21A7717C  main\localized_italian_iw02.iwd
DDF6A75E52331443E365054FC727E013  main\localized_italian_iw03.iwd
CBAACBBDA283F018BBF8913185FE2F83  main\localized_italian_iw04.iwd
98FFFD67DB1E77FC3FA39698CFD59DD6  main\localized_italian_iw05.iwd
E664B8CAAF907BD6FD8032BCA1A7A634  main\video\castle_load.bik
EE80B811C27A1FD37B5B0E45E53D995F  main\video\hamburg_load.bik
02159D7E3F62D8543473A54968FA7E64  main\video\hijack_load.bik
1D54C10A36B41B6E453ACE4D3331C66C  main\video\legal.bik
AA053D34B8852082EAC57C8071D4107E  main\video\london_load.bik
4DDC7CF596F4914C4AAA4D3524571196  main\video\paris_ac130_load.bik
5E0609A7236A5068FEFB2FA6152ACD31  main\video\prague_escape_load.bik
39BB9F244FDDB4498E03670F7F25FCF1  main\video\prologue_select_load.bik
612D8AA1B5A70616D3BF3FCEF6499133  main\video\rescue_2_load.bik
4406FA2B06DC96728D2C249F082B9AFB  main\video\sp_berlin_load.bik
C7BFB97654C1E9F0060350EC7C8B9025  main\video\sp_dubai_load.bik
AC9B7AE3B95D171A26C68EF556D13A90  main\video\sp_intro_load.bik
86F395F333C39211E1D3BB5EC61ABB1C  main\video\sp_ny_harbor_load.bik
40310B29E7F89370BC9B91D658E4E8A1  main\video\sp_ny_manhattan_load.bik
0A4D5177194909C74ECAF548BB1B0DC3  main\video\sp_paris_a_load.bik
0690DA4B73FF25B995B2CF5BCE0CE0F0  main\video\sp_paris_b_load.bik
45D27B6E1BE8434BA357B342E599F2CB  main\video\sp_payback_load.bik
D8274EA5DDFE027A44C30BB5EF341C42  main\video\sp_prague_load.bik
BE34153AF7E55C3148A42C46F6463861  main\video\sp_warlord_load.bik
CD93BC478748779AE4A3A1B9C6105200  main\video\startup.bik
50E4A1D7C0F2A2026AAD6B924584F4AD  main\video\startup_timeline.bik
ABBFBF43CCA4359C97CEC845F4CF6227  zone\italian\berlin.ff
85697F888794C91A8E0C01F2E3D1A3E4  zone\italian\castle.ff
7859592665EFD6DEA45455F9D49ACFAF  zone\italian\code_post_gfx.ff
F99DE016E1B658A37034653572928BBA  zone\italian\code_post_gfx_mp.ff
54BED7DF67772EF23A5E9B6516D7074E  zone\italian\code_pre_gfx.ff
1C599A45304F0C0A768ABAC680609992  zone\italian\code_pre_gfx_mp.ff
15FA8F2C632B3C988BB037C104EBF791  zone\italian\common.ff
78784ABB5391C9D50A7364BC0C9100E4  zone\italian\common_mp.ff
3A2CDC25B4E7FF551FF0A1CD376E9089  zone\italian\common_specialops.ff
38125731E953459C601ADCEE79D0BC55  zone\italian\common_survival.ff
7A876C80B1D0554F6D428F36C962FC4A  zone\italian\dubai.ff
C73071263C97226F70D00015EB3E83AC  zone\italian\hamburg.ff
42002582B6E3BFFDA431B8A845A9FFF2  zone\italian\hijack.ff
2175B2D7BE520B3534C77D84C080FE09  zone\italian\innocent.ff
955FD6097FDEF8C24F2962D91AF658CB  zone\italian\intro.ff
FE0BD2AA6D220654919E3CA8D5E1586C  zone\italian\localized_code_post_gfx_mp.ff
1DC531109121B4B5ECDCE798369D12FF  zone\italian\localized_code_pre_gfx_mp.ff
51760D84EE7C1BCA4D1BCF819D1E7CC6  zone\italian\localized_common_mp.ff
C135F8CB92C60BA0B51DF2F8C21F57BA  zone\italian\localized_ui_mp.ff
1C04135A085DE12348CE3C43A48910DB  zone\italian\london.ff
924F77BCD187BD1CBCB0D150B3A64A48  zone\italian\mp_alpha.ff
E62BD55EE91A68C285CB150056F32D89  zone\italian\mp_alpha_load.ff
ED9BFC4FAED0597617FE7C64431566FE  zone\italian\mp_bootleg.ff
3493149A6039BA602105DD69AC95F70B  zone\italian\mp_bootleg_load.ff
A05C18DB92552BD2BCAE6526405ECC02  zone\italian\mp_bravo.ff
9777FB3AAF0B9FC0B60C25B023AB4C94  zone\italian\mp_bravo_load.ff
24E8078702B4C1E53422D9EC4AD84A81  zone\italian\mp_carbon.ff
A8E93B6211D2B32988D12973524D2B18  zone\italian\mp_carbon_load.ff
227972F7C04125FB6F3C3C681A1BC972  zone\italian\mp_dome.ff
4936FDFE7589877FD71F31E9789D4BAB  zone\italian\mp_dome_load.ff
F323DD8DA2E3BB76C8E9FD4D526B2966  zone\italian\mp_exchange.ff
5F02FD52A19D879E85F8FC4B8FF83F17  zone\italian\mp_exchange_load.ff
7BD66C933F57BDBF98691242BC42DF91  zone\italian\mp_hardhat.ff
239CABA8A4799FCFFC33A73B6C69A391  zone\italian\mp_hardhat_load.ff
2AD0C193175C066F21245B8E9B8602BC  zone\italian\mp_interchange.ff
00F25FADCC0FE3B28614142163E64805  zone\italian\mp_interchange_load.ff
E8D70614AFA15E54AD00BCD7C375FC52  zone\italian\mp_lambeth.ff
6FCF1BFE900CE16FE58601C277BAF037  zone\italian\mp_lambeth_load.ff
8726937A43556CDDD0AF3790F578DF84  zone\italian\mp_mogadishu.ff
710A70169566AD1480146215DC6FB6B6  zone\italian\mp_mogadishu_load.ff
D6E16967ADB121412CD6E18F6B0222C5  zone\italian\mp_paris.ff
CC7C65E062FD46FC55916181C462112C  zone\italian\mp_paris_load.ff
13E93C2C1323C2A8A8732D6EAEB33563  zone\italian\mp_plaza2.ff
B8550154D4F46583161E88339262052B  zone\italian\mp_plaza2_load.ff
B7D825082271D312217DB361960A36D2  zone\italian\mp_radar.ff
EAF23673822DBF63888E849EA0C8889B  zone\italian\mp_radar_load.ff
2AEF7E85303FEE15874F3E08D70C1EE9  zone\italian\mp_seatown.ff
BC8A3B5254CDCCD999BC5C04A12680ED  zone\italian\mp_seatown_load.ff
DAEC31370A7A5F129A1DF388F4B419FA  zone\italian\mp_underground.ff
9E8AD503A7D16E23312F77E8CF197999  zone\italian\mp_underground_load.ff
9F66E9F97CD14E03B70882B76B11B032  zone\italian\mp_village.ff
C78E708C57FB3DF534FFCB9284433EC1  zone\italian\mp_village_load.ff
E762DF19C1B307ACB72D866B7FD03B04  zone\italian\ny_harbor.ff
A738511693666B271FD776C9C67DB631  zone\italian\ny_manhattan.ff
55E6008D366A02B3C5887CE76B2FB68B  zone\italian\paris_a.ff
1F3E98E7EFD6D99299CB8F525825F3B1  zone\italian\paris_ac130.ff
65CBA9E6145E0AECC6E81838131F1B4E  zone\italian\paris_b.ff
3D9B6E5C511BAC1C02CF9A35CAF947C1  zone\italian\patch.ff
0EE214E5858C01E4B12CCB8D84B953E5  zone\italian\patch_hamburg.ff
FC0E75D78D0EDDBAFA739FC44AB2FCCD  zone\italian\patch_hijack.ff
90EA386501984CD3978E814549352FE9  zone\italian\patch_innocent.ff
F0176B27CCBA7D98086A1C4E5D108157  zone\italian\patch_london.ff
482B07B994E12AB516C16881A07A96E7  zone\italian\patch_mp.ff
A155304F10406AB62B25517914A21E48  zone\italian\patch_mp_dome.ff
9D58F92DC8E30DC3BAC7903FB9524EEA  zone\italian\patch_mp_exchange.ff
272EB20A88B9D19CFA3F0A4D4AC8BD84  zone\italian\patch_mp_lambeth.ff
EC01AAFB12DB3C89706417C85042EAAF  zone\italian\patch_mp_paris.ff
C82FC024678B04C44062F8B264ECC320  zone\italian\patch_mp_radar.ff
A8221DC065ACB62FBE8B7468D9DC226F  zone\italian\patch_mp_underground.ff
92E0180EA7AF4B5D9E9CED5605F16E36  zone\italian\patch_mp_village.ff
660BB85C16A4078A03C5FDEF96281397  zone\italian\patch_paris_ac130.ff
0E92A9154F59CA2690018FF4F5EF2824  zone\italian\patch_prague_escape.ff
F2D7F7BD6C15703155830CE59C4FD276  zone\italian\patch_so_ied_berlin.ff
0AC0A5EBB7114E0C994EA2E43FF131B3  zone\italian\patch_so_littlebird_payback.ff
1AAC25317792CA0E738FEC3E9D524109  zone\italian\patch_so_survival_mp_village.ff
8A108FAA78A960694F74DF0B2DED837A  zone\italian\patch_so_zodiac2_ny_harbor.ff
84989C1BF70F957B06EEB750461154C5  zone\italian\patch_sp_berlin.ff
C20EEE0C4A65674BE81F6A9F332CF602  zone\italian\patch_sp_intro.ff
48AAD4F3F7527EBA75AB28378ED0D4CD  zone\italian\patch_sp_ny_harbor.ff
20755460B1BA3A3314FFB374A4F31BD8  zone\italian\patch_sp_ny_manhattan.ff
7DEA5BD3F74DCC7E165CC418EDFE586F  zone\italian\patch_sp_warlord.ff
644C70D5F3D3CE7ABE45DA4CF4DC3E7F  zone\italian\patch_specialops.ff
CAEF06AC338210DD9B26E5DDC1F8E217  zone\italian\patch_survival.ff
B28DC6446D3D423C56FEA0F480CC191D  zone\italian\payback.ff
7FF3C3B3C1523696DA0AD6D32BB354B6  zone\italian\prague.ff
BD92BC513ADF09DEDFCF73388C883247  zone\italian\prague_escape.ff
4E6996E7299AAC4A17C781C97F6725F7  zone\italian\rescue_2.ff
5964A549D7BABB65E538EA83DEABD538  zone\italian\so_assassin_payback.ff
FF3326536DF4D13E85F36DDFDD32B773  zone\italian\so_assault_rescue_2.ff
805A1E194CDD5AEAF7494D443DEFF2CD  zone\italian\so_deltacamp.ff
042D53690DB6EFA7AB9E55DA38B7CBF8  zone\italian\so_heliswitch_berlin.ff
E0A862949162833C03E6F5DA281E0007  zone\italian\so_ied_berlin.ff
40C2D75EB6687FD99DDDB57D35B275E5  zone\italian\so_jeep_paris_b.ff
7FC6B88DF2B098C46A2512A7203D5391  zone\italian\so_killspree_paris_a.ff
990CDC470CBE3C373D2F5D17080FC805  zone\italian\so_littlebird_payback.ff
F7BA6553EC1C9ECC5EEB32403CE4CF40  zone\italian\so_milehigh_hijack.ff
91672CB4282F87627B8F9A5825030399  zone\italian\so_nyse_ny_manhattan.ff
3920CA24E4829915511C4CE6BE9309F1  zone\italian\so_rescue_hijack.ff
67A32CADF4F299F1A86338EDDB27AB28  zone\italian\so_stealth_prague.ff
8B4E9F83710744141323578367A3B2BD  zone\italian\so_stealth_warlord.ff
8711E231D9A9F9034401C29821829D86  zone\italian\so_survival_mp_alpha.ff
103AC808FB44D8873DB28C14BEA87734  zone\italian\so_survival_mp_bootleg.ff
01C194F5AFB4608F2C98CD3500953C5F  zone\italian\so_survival_mp_bravo.ff
3CE988CC0D0936C9F50421EE1A2E517F  zone\italian\so_survival_mp_carbon.ff
185B3DEA3B79D1329C40C66A80AE48E6  zone\italian\so_survival_mp_dome.ff
B30C37DE4E6AE7CF59A49C419D4CD645  zone\italian\so_survival_mp_exchange.ff
6EDB726AEF9FF6CE4B29DC76B270226D  zone\italian\so_survival_mp_hardhat.ff
630966C931D09C7903210CB74BFD1804  zone\italian\so_survival_mp_interchange.ff
23D0604EDAAB778C5D943983DE74F8CD  zone\italian\so_survival_mp_lambeth.ff
CCB46EE7A7FD9F40480D366659C3A6EC  zone\italian\so_survival_mp_mogadishu.ff
BA5C995E1FD5BF8D9BAD33E83F81E60B  zone\italian\so_survival_mp_paris.ff
A95B44A44CBBDAFCF782F38AB82A40FD  zone\italian\so_survival_mp_plaza2.ff
3FBCA3656AB834C4614DDC2650E0975A  zone\italian\so_survival_mp_radar.ff
400D07BFE43D56644E83C636E624EBB0  zone\italian\so_survival_mp_seatown.ff
BB681C56E6E9FBE1F330031A9976FBC5  zone\italian\so_survival_mp_underground.ff
C5884576569215E37F7288E97974897B  zone\italian\so_survival_mp_village.ff
A41D53E01EA7361BD96CE747B5EFD0B8  zone\italian\so_timetrial_london.ff
BA79766ADD1CEA1CDA4116C91630066C  zone\italian\so_trainer2_so_deltacamp.ff
BDC03EA7531B5FED551F039656C25114  zone\italian\so_zodiac2_ny_harbor.ff
36C28701CDFFFAB81AE7A74D9AD97368  zone\italian\sp_berlin.ff
6E5DF01382501082E47BC02D63A030B9  zone\italian\sp_dubai.ff
8AB39CCE31E658332821AC2291E0BDAC  zone\italian\sp_intro.ff
311A9B3BE6F393E4E85291B9314F8454  zone\italian\sp_ny_harbor.ff
3122B5A32F7D26F95B01565ADC01BCDC  zone\italian\sp_ny_manhattan.ff
6B9B464DB6451BC74EE30D573CC11AA5  zone\italian\sp_paris_a.ff
619AFFBA61CE4EF5334857E881617106  zone\italian\sp_paris_b.ff
FAA743D413073576686F07C939DE1D10  zone\italian\sp_payback.ff
BB0023C05A983059671F2A1936D6113A  zone\italian\sp_prague.ff
AD6D377C4AE6F581EE289E6FACA688A2  zone\italian\sp_warlord.ff
9BF42E3D28FE30FB37E67963E818F477  zone\italian\ui.ff
BD0630897873EBBEF1691814BDA56262  zone\italian\ui_mp.ff
41C61A19AF012572FE7FB772F0D3D503  zone\italian\warlord.ff
