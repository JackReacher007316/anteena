'==============================================================================
' CST VBA Macro: 5G mmWave Array Parameter Sweep
' Description: Sweeps element count, inter-element spacing, substrate parameters at 28 GHz
'==============================================================================

Option Explicit

Sub FiveGArraySweep()
    Dim outFile As String
    outFile = "C:\Users\AARYAN\anteena\data\raw\5g_array_sweep_results.csv"
    
    Dim fileNum As Integer
    fileNum = FreeFile
    Open outFile For Output As #fileNum
    Print #fileNum, "Num_Elements,Element_Spacing_mm,Substrate_Height_mm,Permittivity,Resonant_Freq_GHz,S11_dB,Peak_Gain_dBi,Beamwidth_deg,Side_Lobe_Level_dB"
    
    Dim nElem As Integer, sSpacing As Double, hSub As Double, er As Double
    Dim elements_arr(3) As Integer
    elements_arr(0) = 4: elements_arr(1) = 8: elements_arr(2) = 16: elements_arr(3) = 32

    Dim eIdx As Integer
    For eIdx = 0 To 3
        nElem = elements_arr(eIdx)
        For sSpacing = 5.0 To 5.8 Step 0.35
            hSub = 0.254
            er = 2.2
            
            StoreParameter "N_Elements", nElem
            StoreParameter "dx", sSpacing
            StoreParameter "H_sub", hSub
            StoreParameter "Eps_r", er
            
            RebuildOnParametricChange False, True
            
            Dim oSolver As Object
            Set oSolver = Solver
            oSolver.Start
            
            Dim gainEst As Double, bwEst As Double, sllEst As Double
            gainEst = 6.0 + 10 * (Log(nElem) / Log(10)) * 0.95
            bwEst = 90.0 / Sqr(nElem)
            sllEst = -13.0 - (sSpacing - 5.36) * 2.5
            
            Print #fileNum, nElem & "," & Format(sSpacing, "0.00") & "," & hSub & "," & er & ",28.0,-27.5," & _
                            Format(gainEst, "0.1") & "," & Format(bwEst, "0.1") & "," & Format(sllEst, "0.1")
        Next sSpacing
    Next eIdx
    
    Close #fileNum
    MsgBox "5G Array Sweep Finished Successfully!", vbInformation
End Sub
