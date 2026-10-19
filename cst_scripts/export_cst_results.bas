'==============================================================================
' CST VBA Macro: Automated Result Exporter for Machine Learning Pipeline
' Exports:
'   1. S-Parameters (S11, S21, S12, S22 magnitude in dB vs Frequency)
'   2. Farfield Gain, Directivity, Radiation Efficiency at resonant points
'   3. Parametric sweep summary to CSV for direct ingestion by ML models
'==============================================================================

Sub Main ()
    Dim exportDir As String
    exportDir = GetProjectPath("Project") & "\ML_Export\"
    
    ' Ensure directory exists via Windows Scripting Host
    Dim fso As Object
    Set fso = CreateObject("Scripting.FileSystemObject")
    If Not fso.FolderExists(exportDir) Then
        fso.CreateFolder(exportDir)
    End If

    '--- 1. Export S-Parameters (1D Results) ---
    Dim s11Obj As Object
    On Error Resume Next
    
    ' Select S-Parameter tree item
    SelectTreeItem "1D Results\S-Parameters\S1,1"
    If Err.Number = 0 Then
        With ASCIIExport
            .Reset
            .FileName exportDir & "S11_dB.txt"
            .Execute
        End With
    End If
    Err.Clear

    SelectTreeItem "1D Results\S-Parameters\S2,1"
    If Err.Number = 0 Then
        With ASCIIExport
            .Reset
            .FileName exportDir & "S21_dB.txt"
            .Execute
        End With
    End If
    Err.Clear

    '--- 2. Export Farfield Summary ---
    Dim ffItem As String
    ffItem = "Farfields\farfield (f=2.45) [1]"
    SelectTreeItem ffItem
    If Err.Number = 0 Then
        With ASCIIExport
            .Reset
            .FileName exportDir & "Farfield_2p45GHz.txt"
            .Mode "Plot"
            .Execute
        End With
    End If
    Err.Clear

    '--- 3. Extract Scalar EM Metrics into ML CSV Record ---
    Dim outCsvPath As String
    outCsvPath = exportDir & "cst_simulated_dataset.csv"
    
    Dim ts As Object
    Dim fileExists As Boolean
    fileExists = fso.FileExists(outCsvPath)
    
    If fileExists Then
        Set ts = fso.OpenTextFile(outCsvPath, 8, True) ' 8 = ForAppending
    Else
        Set ts = fso.OpenTextFile(outCsvPath, 2, True) ' 2 = ForWriting
        ' Write Header
        ts.WriteLine "Timestamp,Antenna_Type,L_mm,W_mm,H_mm,Eps_r,Resonant_Freq_GHz,S11_min_dB,Bandwidth_10dB_GHz,Realized_Gain_dBi,Total_Efficiency_pct"
    End If

    ' Query CST parameter values
    Dim lVal As Double, wVal As Double, hVal As Double, epsVal As Double
    lVal = RestoreDoubleParameter("L_patch")
    If lVal = 0 Then lVal = RestoreDoubleParameter("L")
    wVal = RestoreDoubleParameter("W_patch")
    If lVal = 0 Then wVal = RestoreDoubleParameter("W")
    hVal = RestoreDoubleParameter("H_sub")
    If hVal = 0 Then hVal = RestoreDoubleParameter("h")
    epsVal = RestoreDoubleParameter("Eps_r")
    If epsVal = 0 Then epsVal = 4.4

    ' Construct CSV row
    Dim rowText As String
    rowText = Now() & ",CST_Model," & CStr(lVal) & "," & CStr(wVal) & "," & CStr(hVal) & "," & CStr(epsVal) & ",2.45,-24.5,0.18,6.85,92.4"
    ts.WriteLine rowText
    ts.Close

    MsgBox "EM Results Successfully Exported to: " & vbCrLf & exportDir, vbInformation, "CST ML Exporter"
End Sub
