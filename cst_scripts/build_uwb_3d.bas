'==============================================================================
' CST VBA Macro: UWB Antenna — FULL 3D MODEL BUILDER
' CPW-fed Circular Disc Monopole with Rectangular Ground Plane Notch
' Band: 3.1 - 10.6 GHz (FCC UWB Standard)
'==============================================================================

Option Explicit

Sub BuildUWBAntenna3D()

    '=== USER PARAMETERS ===
    Dim R        As Double : R        = 12.0   ' Circular disc radius (mm)
    Dim h_sub    As Double : h_sub    = 0.8    ' Substrate height (mm)
    Dim er       As Double : er       = 3.5    ' Rogers RO4003 permittivity
    Dim tand     As Double : tand     = 0.0021 ' Loss tangent
    Dim t        As Double : t        = 0.035  ' Copper thickness (mm)
    Dim W_sub    As Double : W_sub    = 50.0   ' Substrate width (mm)
    Dim L_sub    As Double : L_sub    = 60.0   ' Substrate length (mm)
    Dim g_feed   As Double : g_feed   = 0.5    ' CPW feed gap (mm)
    Dim W_feed   As Double : W_feed   = 2.0    ' CPW center strip width (mm)
    Dim L_gnd    As Double : L_gnd    = 15.0   ' Ground plane length below disc
    Dim notch_W  As Double : notch_W  = 8.0    ' Ground notch width (for BW enhancement)
    Dim notch_H  As Double : notch_H  = 3.0    ' Ground notch height
    Dim disc_y   As Double            ' Disc center Y (above ground gap)

    ' Y position of disc center (touching or slight gap from ground)
    disc_y = L_gnd + g_feed + R

    MsgBox "Building UWB Circular Disc Monopole" & Chr(10) & _
           "Disc R=" & R & "mm | h=" & h_sub & "mm | er=" & er & Chr(10) & _
           "Band: 3.1-10.6 GHz", vbInformation, "CST UWB Builder"

    '=== PROJECT SETUP ===
    With Units
        .SetUnit "Length", "mm"
        .SetUnit "Frequency", "GHz"
        .SetUnit "Time", "ns"
    End With

    '=== MATERIALS ===
    With Material
        .Reset
        .Name "Rogers_RO4003"
        .Colour "0.8", "0.9", "0.75"
        .Epsilon CStr(er)
        .Mue "1.0"
        .TanD CStr(tand)
        .TanDFreq "5.0"
        .Type "Normal"
        .Create
    End With

    '=== SUBSTRATE ===
    With Brick
        .Reset
        .Name "Substrate"
        .Component "UWB"
        .Material "Rogers_RO4003"
        .Xrange CStr(-W_sub/2), CStr(W_sub/2)
        .Yrange "0", CStr(L_sub)
        .Zrange "0", CStr(h_sub)
        .Create
    End With

    '=== BOTTOM GROUND PLANE (CPW-style, split by feed gap) ===
    ' Left ground plane
    With Brick
        .Reset
        .Name "Gnd_Left"
        .Component "UWB"
        .Material "PEC"
        .Xrange CStr(-W_sub/2), CStr(-W_feed/2 - g_feed)
        .Yrange "0", CStr(L_gnd)
        .Zrange CStr(h_sub), CStr(h_sub + t)
        .Create
    End With

    ' Right ground plane
    With Brick
        .Reset
        .Name "Gnd_Right"
        .Component "UWB"
        .Material "PEC"
        .Xrange CStr(W_feed/2 + g_feed), CStr(W_sub/2)
        .Yrange "0", CStr(L_gnd)
        .Zrange CStr(h_sub), CStr(h_sub + t)
        .Create
    End With

    '=== GROUND PLANE NOTCH (enhances bandwidth) ===
    ' Left notch in left ground
    With Brick
        .Reset
        .Name "Notch_L"
        .Component "UWB"
        .Material "Vacuum"
        .Xrange CStr(-W_feed/2 - g_feed - notch_W), CStr(-W_feed/2 - g_feed)
        .Yrange CStr(L_gnd - notch_H), CStr(L_gnd)
        .Zrange CStr(h_sub - 0.001), CStr(h_sub + t + 0.001)
        .Create
    End With
    Solid.Subtract "UWB:Gnd_Left", "UWB:Notch_L"

    ' Right notch in right ground
    With Brick
        .Reset
        .Name "Notch_R"
        .Component "UWB"
        .Material "Vacuum"
        .Xrange CStr(W_feed/2 + g_feed), CStr(W_feed/2 + g_feed + notch_W)
        .Yrange CStr(L_gnd - notch_H), CStr(L_gnd)
        .Zrange CStr(h_sub - 0.001), CStr(h_sub + t + 0.001)
        .Create
    End With
    Solid.Subtract "UWB:Gnd_Right", "UWB:Notch_R"

    '=== CPW FEED LINE ===
    With Brick
        .Reset
        .Name "FeedLine_CPW"
        .Component "UWB"
        .Material "PEC"
        .Xrange CStr(-W_feed/2), CStr(W_feed/2)
        .Yrange "0", CStr(L_gnd + g_feed)
        .Zrange CStr(h_sub), CStr(h_sub + t)
        .Create
    End With

    '=== CIRCULAR RADIATING DISC ===
    With Cylinder
        .Reset
        .Name "Disc"
        .Component "UWB"
        .Material "PEC"
        .OuterRadius CStr(R)
        .InnerRadius "0"
        .Axis "z"
        .Zrange CStr(h_sub), CStr(h_sub + t)
        .Xcenter "0"
        .Ycenter CStr(disc_y)
        .Segments "0"
        .Create
    End With

    '=== BAND-NOTCH FILTER (optional: WiMAX notch at 3.5 GHz) ===
    ' C-shaped slot in disc for band rejection
    Dim notch_r_out As Double : notch_r_out = R * 0.55
    Dim notch_r_in  As Double : notch_r_in  = R * 0.45

    ' Arc slot (approximated as rectangular slots for simplicity)
    With Brick
        .Reset
        .Name "BandNotch_Slot"
        .Component "UWB"
        .Material "Vacuum"
        .Xrange CStr(-notch_r_out), CStr(-notch_r_in)
        .Yrange CStr(disc_y - 1), CStr(disc_y + 1)
        .Zrange CStr(h_sub - 0.001), CStr(h_sub + t + 0.001)
        .Create
    End With
    Solid.Subtract "UWB:Disc", "UWB:BandNotch_Slot"

    '=== SMA FEED PORT ===
    With Port
        .Reset
        .PortNumber "1"
        .Label "UWB_Feed"
        .NumberOfModes "1"
        .Coordinates "Free"
        .Orientation "ymin"
        .Xrange CStr(-W_feed/2), CStr(W_feed/2)
        .Yrange "0", "0"
        .Zrange "0", CStr(h_sub + t)
        .Create
    End With

    '=== BOUNDARY CONDITIONS ===
    With Boundary
        .Xmin "expanded open"
        .Xmax "expanded open"
        .Ymin "expanded open"
        .Ymax "expanded open"
        .Zmin "expanded open"
        .Zmax "expanded open"
    End With

    '=== FREQUENCY RANGE: UWB ===
    With Solver
        .FrequencyRange "1.0", "12.0"
    End With

    '=== MESH SETTINGS (fine for UWB) ===
    With MeshSettings
        .SetMeshType "Hex"
        .Set "StepsPerWaveNear", "30"
        .Set "StepsPerWaveFar",  "15"
    End With

    '=== MONITORS ===
    Dim fList(5) As Double
    fList(0) = 3.5 : fList(1) = 5.0 : fList(2) = 6.85 : fList(3) = 8.0 : fList(4) = 10.0

    Dim i As Integer
    For i = 0 To 4
        With Monitor
            .Reset
            .Name "farfield_" & CStr(fList(i)) & "GHz"
            .Domain "Frequency"
            .FieldType "Farfield"
            .Frequency CStr(fList(i))
            .Create
        End With
    Next i

    ' Time domain monitor for pulse analysis (UWB-specific)
    With Monitor
        .Reset
        .Name "efield_timedomain"
        .Domain "Time"
        .FieldType "Efield"
        .Tstart "0"
        .Tstep "0.1"
        .Tend "3"
        .Create
    End With

    '=== PARAMETER STORE ===
    StoreParameter "uwb_disc_radius",  R
    StoreParameter "uwb_feed_gap",     g_feed
    StoreParameter "uwb_feed_width",   W_feed
    StoreParameter "uwb_gnd_length",   L_gnd
    StoreParameter "uwb_notch_width",  notch_W
    StoreParameter "uwb_notch_height", notch_H

    MsgBox "UWB 3D model complete!" & Chr(10) & _
           "Circular Disc R=" & R & "mm" & Chr(10) & _
           "CPW feed gap=" & g_feed & "mm" & Chr(10) & _
           "WiMAX band-notch slot added" & Chr(10) & _
           "Frequency: 1-12 GHz", vbInformation, "UWB Build Complete"

End Sub


'==============================================================================
' Sub: Build UWB with Elliptical Disc (alternative - better omnidirectional)
'==============================================================================
Sub BuildUWBElliptical3D()

    Dim a_axis  As Double : a_axis  = 14.0  ' Semi-major axis (mm)
    Dim b_axis  As Double : b_axis  = 11.0  ' Semi-minor axis (mm)
    Dim h_sub   As Double : h_sub   = 0.8
    Dim g_feed  As Double : g_feed  = 0.4
    Dim W_feed  As Double : W_feed  = 1.8

    With Ellipsoid
        .Reset
        .Name "EllipticalDisc"
        .Component "UWB_Elliptical"
        .Material "PEC"
        .Axis "z"
        .Xradius CStr(a_axis)
        .Yradius CStr(b_axis)
        .Zradius CStr(0.035)
        .Xcenter "0"
        .Ycenter CStr(15 + g_feed + b_axis)
        .Zcenter CStr(0.8)
        .Segments "0"
        .Create
    End With

End Sub
