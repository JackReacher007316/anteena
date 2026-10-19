'==============================================================================
' CST VBA Macro: Patch Antenna — FULL 3D MODEL BUILDER
' Builds complete patch antenna geometry from scratch in CST Studio Suite
' Antenna: Rectangular Microstrip Patch on Dielectric Substrate
'==============================================================================

Option Explicit

Sub BuildPatchAntenna3D()

    '=== USER PARAMETERS (modify these) ===
    Dim L   As Double   : L   = 25.0   ' Patch length (mm)
    Dim W   As Double   : W   = 25.0   ' Patch width (mm)
    Dim h   As Double   : h   = 1.6    ' Substrate height (mm)
    Dim er  As Double   : er  = 4.4    ' Relative permittivity (FR-4)
    Dim tand As Double  : tand = 0.02  ' Loss tangent
    Dim t   As Double   : t   = 0.035  ' Copper thickness (mm)
    Dim freq As Double  : freq = 2.4   ' Operating frequency (GHz)
    Dim Wf  As Double   ' Feed line width (auto-calculated)
    Dim Lf  As Double   ' Feed line length
    Dim L0  As Double   ' Inset feed notch depth
    Dim W0  As Double   ' Inset feed notch width

    ' Ground plane margin
    Dim margin As Double : margin = 6*h

    ' Feed line width for 50 Ohm (Hammerstein formula)
    Wf = CalculateFeedWidth(er, h)
    Lf = 10.0  ' Feed line length (mm)

    ' Inset feed position for impedance matching
    Dim G As Double : G = 1 / (90 * (er / (er - 1)) * (L / W) ^ 2)
    L0 = (1 / (3.14159)) * Atn(Sqr(1 / G - 1)) * L
    W0 = Wf + 2.0

    MsgBox "Building Patch Antenna: L=" & L & "mm, W=" & W & "mm, h=" & h & "mm, er=" & er, vbInformation, "CST Patch Builder"

    '=== STEP 1: PROJECT SETUP ===
    With Units
        .SetUnit "Length", "mm"
        .SetUnit "Frequency", "GHz"
        .SetUnit "Time", "ns"
    End With

    With Background
        .Type "Normal"
        .XminSpace "0"; .XmaxSpace "0"; .YminSpace "0"; .YmaxSpace "0"
        .ZminSpace "0"; .ZmaxSpace "0"
    End With

    '=== STEP 2: DEFINE MATERIALS ===
    ' Substrate (FR-4 / Rogers)
    With Material
        .Reset
        .Name "Substrate"
        .Colour "0.94", "0.82", "0.76"
        .Epsilon CStr(er)
        .Mue "1.0"
        .TanD CStr(tand)
        .TanDFreq CStr(freq)
        .Type "Normal"
        .Create
    End With

    ' Copper
    With Material
        .Reset
        .Name "Copper"
        .FrqType "all"
        .Type "Ohmic sheet"
        .Sigma "5.8e7"
        .Create
    End With

    '=== STEP 3: GROUND PLANE ===
    Dim GW As Double : GW = W + 2*margin
    Dim GL As Double : GL = L + 2*margin + Lf

    With Brick
        .Reset
        .Name "GroundPlane"
        .Component "Antenna"
        .Material "PEC"
        .Xrange CStr(-GL/2), CStr(GL/2)
        .Yrange CStr(-GW/2), CStr(GW/2)
        .Zrange CStr(-t), "0"
        .Create
    End With

    '=== STEP 4: DIELECTRIC SUBSTRATE ===
    With Brick
        .Reset
        .Name "Substrate"
        .Component "Antenna"
        .Material "Substrate"
        .Xrange CStr(-GL/2), CStr(GL/2)
        .Yrange CStr(-GW/2), CStr(GW/2)
        .Zrange "0", CStr(h)
        .Create
    End With

    '=== STEP 5: PATCH CONDUCTOR ===
    With Brick
        .Reset
        .Name "Patch"
        .Component "Antenna"
        .Material "PEC"
        .Xrange CStr(-L/2), CStr(L/2)
        .Yrange CStr(-W/2), CStr(W/2)
        .Zrange CStr(h), CStr(h+t)
        .Create
    End With

    '=== STEP 6: INSET FEED NOTCHES (for impedance matching) ===
    ' Left notch
    With Brick
        .Reset
        .Name "Notch_Left"
        .Component "Antenna"
        .Material "Vacuum"
        .Xrange CStr(-L/2), CStr(-L/2+L0)
        .Yrange CStr(-W0/2), CStr(-Wf/2)
        .Zrange CStr(h), CStr(h+t+0.001)
        .Create
    End With
    Solid.Subtract "Antenna:Patch", "Antenna:Notch_Left"

    ' Right notch
    With Brick
        .Reset
        .Name "Notch_Right"
        .Component "Antenna"
        .Material "Vacuum"
        .Xrange CStr(-L/2), CStr(-L/2+L0)
        .Yrange CStr(Wf/2), CStr(W0/2)
        .Zrange CStr(h), CStr(h+t+0.001)
        .Create
    End With
    Solid.Subtract "Antenna:Patch", "Antenna:Notch_Right"

    '=== STEP 7: INSET FEED LINE ===
    With Brick
        .Reset
        .Name "FeedLine"
        .Component "Antenna"
        .Material "PEC"
        .Xrange CStr(-L/2-Lf), CStr(-L/2+L0)
        .Yrange CStr(-Wf/2), CStr(Wf/2)
        .Zrange CStr(h), CStr(h+t)
        .Create
    End With

    '=== STEP 8: COAXIAL FEED PORT (SMA-style) ===
    ' Feed port at the end of feed line
    Dim port_x As Double : port_x = -L/2 - Lf
    Dim port_r As Double : port_r = Wf/2

    With Port
        .Reset
        .PortNumber "1"
        .Label "Coax_Feed"
        .Folder ""
        .NumberOfModes "1"
        .AdjustPolarization False
        .PolarizationAngle "0.0"
        .ReferencePlaneDistance "0"
        .TextSize "50"
        .TextMaxLimit "0"
        .Coordinates "Free"
        .Orientation "xmin"
        .PortOnBound "False"
        .ClipPickedPortToBound "False"
        .Xrange CStr(port_x), CStr(port_x)
        .Yrange CStr(-port_r), CStr(port_r)
        .Zrange "0", CStr(h+t)
        .XrangeAdd "0.0", "0.0"
        .YrangeAdd "0.0", "0.0"
        .ZrangeAdd "0.0", "0.0"
        .SingleEnded "False"
        .WaveguideMonitor "False"
        .Create
    End With

    '=== STEP 9: BOUNDARY CONDITIONS ===
    With Boundary
        .Xmin "expanded open"
        .Xmax "expanded open"
        .Ymin "expanded open"
        .Ymax "expanded open"
        .Zmin "expanded open"
        .Zmax "expanded open"
        .ApplyInAllDirections False
    End With

    '=== STEP 10: FREQUENCY RANGE & MESH ===
    With Solver
        .FrequencyRange CStr(freq * 0.5), CStr(freq * 2.5)
    End With

    With MeshSettings
        .SetMeshType "Hex"
        .Set "StepsPerWaveNear", "20"
        .Set "StepsPerWaveFar",  "10"
        .Set "MinimumStepNumber", "5"
        .Set "RatioLimitGeometry", "10"
    End With

    '=== STEP 11: FARFIELD MONITOR ===
    With Monitor
        .Reset
        .Name "farfield_" & CStr(freq) & "GHz"
        .Domain "Frequency"
        .FieldType "Farfield"
        .Frequency CStr(freq)
        .ExportFarfieldSource False
        .Create
    End With

    ' E-field monitor at resonance
    With Monitor
        .Reset
        .Name "efield_" & CStr(freq) & "GHz"
        .Domain "Frequency"
        .FieldType "Efield"
        .Frequency CStr(freq)
        .Create
    End With

    '=== STEP 12: PARAMETER STORE (for sweep) ===
    StoreParameter "patch_length", L
    StoreParameter "patch_width",  W
    StoreParameter "sub_height",   h
    StoreParameter "sub_permittivity", er
    StoreParameter "feed_width",   Wf
    StoreParameter "inset_depth",  L0
    StoreParameter "freq_design",  freq

    '=== DONE ===
    MsgBox "Patch Antenna 3D model built successfully!" & Chr(10) & _
           "Patch: " & L & " x " & W & " mm" & Chr(10) & _
           "Substrate: h=" & h & " mm, er=" & er & Chr(10) & _
           "Feed width: " & Format(Wf, "0.00") & " mm" & Chr(10) & _
           "Inset depth: " & Format(L0, "0.00") & " mm", _
           vbInformation, "Build Complete"

End Sub

'==============================================================================
' Calculate 50-Ohm microstrip feed line width
' Based on Wheeler/Schneider formulas
'==============================================================================
Function CalculateFeedWidth(er As Double, h As Double) As Double
    Dim A As Double, B As Double
    Dim Wf As Double
    A = (60 / 50) * Sqr((er + 1) / 2) + ((er - 1) / (er + 1)) * (0.23 + 0.11 / er)
    B = 377 * 3.14159 / (2 * 50 * Sqr(er))
    ' Initial estimate
    Wf = 8 * h * Exp(A) / (Exp(2 * A) - 2)
    If Wf / h < 2 Then
        CalculateFeedWidth = Wf
    Else
        Wf = (2 * h / 3.14159) * (B - 1 - Log(2*B - 1) + (er-1)/(2*er) * (Log(B-1) + 0.39 - 0.61/er))
        CalculateFeedWidth = Wf
    End If
End Function
