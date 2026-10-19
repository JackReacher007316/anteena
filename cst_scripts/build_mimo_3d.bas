'==============================================================================
' CST VBA Macro: MIMO Antenna — FULL 3D MODEL BUILDER
' 2-Port MIMO Planar Inverted-F Antenna (PIFA) Array
' Designed for 2.4 / 5.0 GHz dual-band WLAN/WiFi operation
'==============================================================================

Option Explicit

Sub BuildMIMOAntenna3D()

    '=== USER PARAMETERS ===
    Dim freq1    As Double : freq1    = 2.4    ' Lower band (GHz)
    Dim freq2    As Double : freq2    = 5.0    ' Upper band (GHz)
    Dim h_sub    As Double : h_sub    = 1.0    ' Substrate height (mm)
    Dim er       As Double : er       = 4.4    ' Substrate permittivity
    Dim t        As Double : t        = 0.035  ' Copper thickness (mm)
    Dim spacing  As Double : spacing  = 25.0   ' Element center-to-center (mm)

    ' Ground plane dimensions
    Dim GP_L As Double : GP_L = 80.0   ' Ground plane length (mm)
    Dim GP_W As Double : GP_W = 60.0   ' Ground plane width (mm)

    ' PIFA element dimensions (per element)
    Dim PA_L As Double : PA_L = 18.0   ' Patch arm length
    Dim PA_W As Double : PA_W = 10.0   ' Patch arm width
    Dim slot_L As Double : slot_L = 10.0 ' Slot length for dual-band
    Dim slot_W As Double : slot_W = 1.0  ' Slot width
    Dim short_L As Double : short_L = 2.0 ' Short circuit pin width
    Dim short_W As Double : short_W = 2.0

    MsgBox "Building 2-Port MIMO PIFA Antenna" & Chr(10) & _
           "Spacing: " & spacing & "mm | Bands: " & freq1 & "/" & freq2 & " GHz", _
           vbInformation, "CST MIMO Builder"

    '=== PROJECT SETUP ===
    With Units
        .SetUnit "Length", "mm"
        .SetUnit "Frequency", "GHz"
    End With

    '=== MATERIALS ===
    With Material
        .Reset
        .Name "FR4_MIMO"
        .Colour "0.9", "0.85", "0.7"
        .Epsilon CStr(er)
        .Mue "1.0"
        .TanD "0.02"
        .Type "Normal"
        .Create
    End With

    '=== COMPONENT: GROUND PLANE (shared for both elements) ===
    With Brick
        .Reset
        .Name "GroundPlane"
        .Component "MIMO"
        .Material "PEC"
        .Xrange CStr(-GP_L/2), CStr(GP_L/2)
        .Yrange CStr(-GP_W/2), CStr(GP_W/2)
        .Zrange CStr(-t), "0"
        .Create
    End With

    '=== COMPONENT: SUBSTRATE ===
    With Brick
        .Reset
        .Name "Substrate"
        .Component "MIMO"
        .Material "FR4_MIMO"
        .Xrange CStr(-GP_L/2), CStr(GP_L/2)
        .Yrange CStr(-GP_W/2), CStr(GP_W/2)
        .Zrange "0", CStr(h_sub)
        .Create
    End With

    '=== BUILD ELEMENT 1 (left) ===
    BuildPIFAElement "1", -spacing/2, GP_W, h_sub, t, PA_L, PA_W, slot_L, slot_W, short_L, short_W

    '=== BUILD ELEMENT 2 (right, mirrored) ===
    BuildPIFAElement "2",  spacing/2, GP_W, h_sub, t, PA_L, PA_W, slot_L, slot_W, short_L, short_W

    '=== DECOUPLING STRUCTURE (Neutralization Line) ===
    ' A thin strip connecting the two ground pins to improve isolation
    Dim nl_z As Double : nl_z = h_sub
    With Brick
        .Reset
        .Name "NeutralizationLine"
        .Component "Decoupling"
        .Material "PEC"
        .Xrange CStr(-spacing/2 + short_L), CStr(spacing/2 - short_L)
        .Yrange CStr(-GP_W/2 + 5), CStr(-GP_W/2 + 5 + 0.8)
        .Zrange CStr(nl_z), CStr(nl_z + t)
        .Create
    End With

    '=== FREQUENCY RANGE ===
    With Solver
        .FrequencyRange "1.5", "7.0"
    End With

    '=== S-PARAMETER MONITORS ===
    With Monitor
        .Reset
        .Name "farfield_2.4GHz"
        .Domain "Frequency"
        .FieldType "Farfield"
        .Frequency "2.4"
        .Create
    End With

    With Monitor
        .Reset
        .Name "farfield_5.0GHz"
        .Domain "Frequency"
        .FieldType "Farfield"
        .Frequency "5.0"
        .Create
    End With

    '=== BOUNDARY CONDITIONS (Absorbing for radiation) ===
    With Boundary
        .Xmin "expanded open"
        .Xmax "expanded open"
        .Ymin "expanded open"
        .Ymax "expanded open"
        .Zmin "expanded open"
        .Zmax "expanded open"
    End With

    '=== PARAMETER STORE ===
    StoreParameter "mimo_spacing",  spacing
    StoreParameter "pifa_length",   PA_L
    StoreParameter "pifa_width",    PA_W
    StoreParameter "slot_length",   slot_L
    StoreParameter "freq_band1",    freq1
    StoreParameter "freq_band2",    freq2

    MsgBox "MIMO 3D model complete!" & Chr(10) & _
           "2-Port PIFA | Spacing=" & spacing & "mm" & Chr(10) & _
           "Neutralization decoupling line added", vbInformation, "MIMO Build Complete"

End Sub

'==============================================================================
' Sub: Build one PIFA element with slot (dual-band) and short pin
'==============================================================================
Sub BuildPIFAElement(suffix As String, cx As Double, GP_W As Double, _
                     h_sub As Double, t As Double, _
                     PA_L As Double, PA_W As Double, _
                     slot_L As Double, slot_W As Double, _
                     short_L As Double, short_W As Double)

    Dim z_top As Double : z_top = h_sub + t
    Dim y_start As Double : y_start = -GP_W/2 + 5.0  ' 5mm from edge

    ' Patch arm (horizontal)
    With Brick
        .Reset
        .Name "PatchArm_" & suffix
        .Component "Element" & suffix
        .Material "PEC"
        .Xrange CStr(cx - PA_W/2), CStr(cx + PA_W/2)
        .Yrange CStr(y_start), CStr(y_start + PA_L)
        .Zrange CStr(h_sub), CStr(h_sub + t)
        .Create
    End With

    ' Slot in patch for dual-band (U-slot)
    With Brick
        .Reset
        .Name "Slot_" & suffix
        .Component "Element" & suffix
        .Material "Vacuum"
        .Xrange CStr(cx - slot_W/2), CStr(cx + slot_W/2)
        .Yrange CStr(y_start + 2), CStr(y_start + 2 + slot_L)
        .Zrange CStr(h_sub - 0.001), CStr(h_sub + t + 0.001)
        .Create
    End With
    Solid.Subtract "Element" & suffix & ":PatchArm_" & suffix, "Element" & suffix & ":Slot_" & suffix

    ' Short circuit pin (connects patch to ground — PIFA characteristic)
    With Brick
        .Reset
        .Name "ShortPin_" & suffix
        .Component "Element" & suffix
        .Material "PEC"
        .Xrange CStr(cx - PA_W/2), CStr(cx - PA_W/2 + short_L)
        .Yrange CStr(y_start), CStr(y_start + short_W)
        .Zrange CStr(-0.001), CStr(h_sub + t)
        .Create
    End With

    ' Feed probe (coaxial inner conductor)
    With Cylinder
        .Reset
        .Name "Probe_" & suffix
        .Component "Element" & suffix
        .Material "PEC"
        .OuterRadius "0.65"
        .InnerRadius "0"
        .Axis "z"
        .Zrange "0", CStr(h_sub)
        .Xcenter CStr(cx + 2)
        .Ycenter CStr(y_start + 4)
        .Segments "0"
        .Create
    End With

    ' SMA Port
    With Port
        .Reset
        .PortNumber suffix
        .Label "Port_" & suffix
        .NumberOfModes "1"
        .Coordinates "Free"
        .Orientation "zmin"
        .Xrange CStr(cx - 1), CStr(cx + 1)
        .Yrange CStr(y_start + 3), CStr(y_start + 5)
        .Zrange "0", "0"
        .Create
    End With

End Sub
