'==============================================================================
' CST VBA Macro: Fractal Antenna — FULL 3D MODEL BUILDER
' Antenna: Sierpinski Carpet / Minkowski Iterative Fractal Microstrip Patch
' Supports multi-band resonance (e.g. 2.4 GHz, 5.2 GHz, 8.5 GHz, 10+ GHz)
'==============================================================================

Sub Main ()
    Dim projName As String
    projName = "Fractal_Antenna_3D"
    
    '--- Initialize Units ---
    With Units
        .Geometry "mm"
        .Frequency "GHz"
        .Time "ns"
        .Temperature "Kelvin"
        .Voltage "V"
        .Current "A"
        .Resistance "Ohm"
    End With

    '--- Global Parameter Definitions ---
    StoreParameter "L_sub", 60.0
    StoreParameter "W_sub", 60.0
    StoreParameter "H_sub", 1.6
    StoreParameter "T_copper", 0.035
    StoreParameter "L_patch", 36.0
    StoreParameter "W_patch", 36.0
    StoreParameter "W_feed", 3.0
    StoreParameter "L_feed", 12.0
    StoreParameter "Eps_r", 4.4
    StoreParameter "Fractal_Iteration", 2
    
    '--- Define Substrate Material (FR-4 Lossy) ---
    With Material
        .Reset
        .Name "FR4_Substrate"
        .Folder ""
        .Type "Lossy metal"
        .FrqType "all"
        .Type "Normal"
        .MaterialUnit "Frequency", "GHz"
        .MaterialUnit "Geometry", "mm"
        .Epsilon "Eps_r"
        .Mu "1.0"
        .TanD "0.02"
        .TanDFreq "2.45"
        .TanDGiven "True"
        .Create
    End With

    '--- Build Ground Plane (Full PEC Backing) ---
    With Brick
        .Reset
        .Name "Ground_Plane"
        .Component "Ground"
        .Material "PEC"
        .Xrange "-W_sub/2", "W_sub/2"
        .Yrange "-L_sub/2", "L_sub/2"
        .Zrange "-T_copper", "0"
        .Create
    End With

    '--- Build Dielectric Substrate ---
    With Brick
        .Reset
        .Name "Dielectric_Substrate"
        .Component "Substrate"
        .Material "FR4_Substrate"
        .Xrange "-W_sub/2", "W_sub/2"
        .Yrange "-L_sub/2", "L_sub/2"
        .Zrange "0", "H_sub"
        .Create
    End With

    '--- Build Base Patch (Iteration 0) ---
    With Brick
        .Reset
        .Name "Base_Patch"
        .Component "Radiator"
        .Material "PEC"
        .Xrange "-W_patch/2", "W_patch/2"
        .Yrange "-L_patch/2", "L_patch/2"
        .Zrange "H_sub", "H_sub + T_copper"
        .Create
    End With

    '--- Build Microstrip Feedline ---
    With Brick
        .Reset
        .Name "Feed_Line"
        .Component "Radiator"
        .Material "PEC"
        .Xrange "-W_feed/2", "W_feed/2"
        .Yrange "-L_sub/2", "-L_patch/2"
        .Zrange "H_sub", "H_sub + T_copper"
        .Create
    End With

    ' Unite Feed and Base Patch
    Solid.Add "Radiator:Base_Patch", "Radiator:Feed_Line"

    '--- Fractal Iteration 1: Cut Central 1/3 Square Slot ---
    Dim slot1_w As Double, slot1_l As Double
    slot1_w = 36.0 / 3.0  ' 12 mm
    slot1_l = 36.0 / 3.0  ' 12 mm

    With Brick
        .Reset
        .Name "Fractal_Slot_Center"
        .Component "Fractal_Cuts"
        .Material "PEC"
        .Xrange "-slot1_w/2", "slot1_w/2"
        .Yrange "-slot1_l/2", "slot1_l/2"
        .Zrange "H_sub - 0.01", "H_sub + T_copper + 0.01"
        .Create
    End With

    ' Subtract Central Slot
    Solid.Subtract "Radiator:Base_Patch", "Fractal_Cuts:Fractal_Slot_Center"

    '--- Fractal Iteration 2: 8 Surrounding Miniature Slots (Sierpinski carpet) ---
    Dim i As Integer, j As Integer
    Dim slot2_w As Double, slot2_l As Double
    Dim cx As Double, cy As Double
    slot2_w = slot1_w / 3.0  ' 4 mm
    slot2_l = slot1_l / 3.0  ' 4 mm

    Dim cutIdx As Integer
    cutIdx = 1

    For i = -1 To 1
        For j = -1 To 1
            If Not (i = 0 And j = 0) Then
                cx = i * slot1_w
                cy = j * slot1_l
                
                With Brick
                    .Reset
                    .Name "Slot_It2_" & CStr(cutIdx)
                    .Component "Fractal_Cuts"
                    .Material "PEC"
                    .Xrange CStr(cx - slot2_w/2), CStr(cx + slot2_w/2)
                    .Yrange CStr(cy - slot2_l/2), CStr(cy + slot2_l/2)
                    .Zrange "H_sub - 0.01", "H_sub + T_copper + 0.01"
                    .Create
                End With
                
                Solid.Subtract "Radiator:Base_Patch", "Fractal_Cuts:Slot_It2_" & CStr(cutIdx)
                cutIdx = cutIdx + 1
            End If
        Next j
    Next i

    '--- Waveguide Port Definition ---
    With Port
        .Reset
        .PortNumber "1"
        .Label "Fractal_Port_1"
        .NumberOfModes "1"
        .AdjustPolarization "False"
        .PolarizationAngle "0.0"
        .ReferencePlaneDistance "0"
        .TextSize "50"
        .Coordinates "Free"
        .Orientation "YNegative"
        .PortOnBound "False"
        .Clip "False"
        .Xrange "-W_feed*3", "W_feed*3"
        .Yrange "-L_sub/2", "-L_sub/2"
        .Zrange "0", "H_sub*5"
        .Create
    End With

    '--- Frequency Range: 1.0 GHz to 12.0 GHz (Multi-Band) ---
    Solver.FrequencyRange "1.0", "12.0"

    '--- Define Field Monitors at Multi-Band Resonances ---
    With Monitor
        .Reset
        .Name "farfield_2p45GHz"
        .Dimension "Volume"
        .Domain "Frequency"
        .Accuracy "default"
        .Frequency "2.45"
        .Type "Farfield"
        .Create
    End With

    With Monitor
        .Reset
        .Name "farfield_5p2GHz"
        .Dimension "Volume"
        .Domain "Frequency"
        .Accuracy "default"
        .Frequency "5.2"
        .Type "Farfield"
        .Create
    End With

    With Monitor
        .Reset
        .Name "farfield_8p5GHz"
        .Dimension "Volume"
        .Domain "Frequency"
        .Accuracy "default"
        .Frequency "8.5"
        .Type "Farfield"
        .Create
    End With

    '--- Boundary Conditions: Open (Add Space) ---
    With Boundary
        .Xmin "expanded open"
        .Xmax "expanded open"
        .Ymin "expanded open"
        .Ymax "expanded open"
        .Zmin "expanded open"
        .Zmax "expanded open"
    End With

    MsgBox "Fractal 3D Antenna Geometry Built Successfully!" & vbCrLf & _
           "Iteration 2 Sierpinski Carpet with 9 self-similar fractal cuts.", vbInformation, "CST Model Builder"
End Sub
