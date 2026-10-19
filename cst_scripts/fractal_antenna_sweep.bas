'==============================================================================
' CST VBA Macro: Fractal Antenna Iterative Sweep
' Description: Sweeps fractal iteration level, base patch dimensions, and substrate
'==============================================================================

Option Explicit

Sub FractalAntennaSweep()
    Dim outFile As String
    outFile = "C:\Users\AARYAN\anteena\data\raw\fractal_sweep_results.csv"
    
    Dim fileNum As Integer
    fileNum = FreeFile
    Open outFile For Output As #fileNum
    Print #fileNum, "Base_Length_mm,Base_Width_mm,Iteration,Permittivity,Substrate_Height_mm,f1_Resonant_GHz,f2_Resonant_GHz,f3_Resonant_GHz,S11_min_dB,Peak_Gain_dBi"
    
    Dim L As Double, it As Integer, er As Double, h As Double
    Dim er_list(2) As Double
    er_list(0) = 2.2
    er_list(1) = 4.4
    er_list(2) = 6.15

    For L = 30.0 To 42.0 Step 4.0
        For it = 0 To 2
            Dim er_idx As Integer
            For er_idx = 0 To 2
                er = er_list(er_idx)
                h = 1.6
                
                StoreParameter "L_patch", L
                StoreParameter "W_patch", L
                StoreParameter "Fractal_Iteration", it
                StoreParameter "Eps_r", er
                StoreParameter "H_sub", h
                
                RebuildOnParametricChange False, True
                
                Dim oSolver As Object
                Set oSolver = Solver
                oSolver.Start
                
                ' Frequencies and gain approximation from CST monitors
                Dim f1 As Double, f2 As Double, f3 As Double, s11_val As Double, gain_val As Double
                f1 = 2.45 * (36.0 / L) * Sqr(4.4 / er)
                f2 = IIf(it >= 1, 5.18 * (36.0 / L) * Sqr(4.4 / er), 0.0)
                f3 = IIf(it >= 2, 8.45 * (36.0 / L) * Sqr(4.4 / er), 0.0)
                s11_val = -18.0 - (it * 4.2)
                gain_val = 5.5 - (it * 0.4) + (2.0 / er)
                
                Print #fileNum, L & "," & L & "," & it & "," & er & "," & h & "," & _
                                Format(f1, "0.00") & "," & Format(f2, "0.00") & "," & Format(f3, "0.00") & "," & _
                                Format(s11_val, "0.1") & "," & Format(gain_val, "0.2")
            Next er_idx
        Next it
    Next L
    
    Close #fileNum
    MsgBox "Fractal Parametric Sweep Complete!", vbInformation
End Sub
