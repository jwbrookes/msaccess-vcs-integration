Attribute VB_Name = "AppCodeImportExport"
' Access Module `AppCodeImportExport`
' -----------------------------------
'
' Version 0.3
'
' https://github.com/bkidwell/msaccess-vcs-integration
'
' Brendan Kidwell
'
' This code is licensed under BSD-style terms.
'
' This is some code for importing and exporting Access Queries, Forms,
' Reports, Macros, and Modules to and from plain text files, for the
' purpose of syncing with a version control system.
'
'
' Use:
'
' BACKUP YOUR WORK BEFORE TRYING THIS CODE!
'
' To create and/or overwrite source text files for all database objects
' (except tables) in "$database-folder/source/", run
' `ExportAllSource()`.
'
' To load and/or overwrite  all database objects from source files in
' "$database-folder/source/", run `ImportAllSource()`.
'
' See project home page (URL above) for more information.
'
'
' Future expansion:
' * Maybe integrate into a dialog box triggered by a menu item.
' * Warning of destructive overwrite.

Option Compare Database
Option Explicit

' --------------------------------
' Configuration
' --------------------------------

' List of lookup tables that are part of the program rather than the
' data, to be exported with contained data
'
' Provide a comma separated list of table names, or an empty string
' ("") if no data tables are to be exported.

Private Const DATA_TABLES = ""

' Do more aggressive removal of superfluous blobs from exported MS
' Access source code?

Private Const AggressiveSanitize = True


' --------------------------------
' Structures
' --------------------------------

' Structure to track buffered reading or writing of binary files
Private Type BinFile
    file_num As Integer
    file_len As Long
    file_pos As Long
    buffer As String
    buffer_len As Integer
    buffer_pos As Integer
    at_eof As Boolean
    mode As String
End Type

' --------------------------------
' Constants
' --------------------------------

' Constants for Scripting.FileSystemObject API
Const ForReading = 1, ForWriting = 2, ForAppending = 8
Const TristateTrue = -1, TristateFalse = 0, TristateUseDefault = -2

' --------------------------------
' Module variables
' --------------------------------

' Does the current database file write UCS2-little-endian when exporting
' Queries, Forms, Reports, Macros
Private UsingUcs2 As Boolean

' --------------------------------
' Basic functions missing from VB 6: buffered file read/write, string builder
' --------------------------------

' Open a binary file for reading (mode = 'r') or writing (mode = 'w').
Private Function BinOpen(file_path As String, mode As String) As BinFile
    Dim f As BinFile

    f.file_num = FreeFile
    f.mode = LCase(mode)
    If f.mode = "r" Then
        Open file_path For Binary Access Read As f.file_num
        f.file_len = LOF(f.file_num)
        f.file_pos = 0
        If f.file_len > &H4000 Then
            f.buffer = String(&H4000, " ")
            f.buffer_len = &H4000
        Else
            f.buffer = String(f.file_len, " ")
            f.buffer_len = f.file_len
        End If
        f.buffer_pos = 0
        Get f.file_num, f.file_pos + 1, f.buffer
    Else
        DelIfExist file_path
        Open file_path For Binary Access Write As f.file_num
        f.file_len = 0
        f.file_pos = 0
        f.buffer = String(&H4000, " ")
        f.buffer_len = 0
        f.buffer_pos = 0
    End If

    BinOpen = f
End Function

' Buffered read one byte at a time from a binary file.
Private Function BinRead(ByRef f As BinFile) As Integer
    If f.at_eof = True Then
        BinRead = 0
        Exit Function
    End If

    BinRead = Asc(Mid(f.buffer, f.buffer_pos + 1, 1))

    f.buffer_pos = f.buffer_pos + 1
    If f.buffer_pos >= f.buffer_len Then
        f.file_pos = f.file_pos + &H4000
        If f.file_pos >= f.file_len Then
            f.at_eof = True
            Exit Function
        End If
        If f.file_len - f.file_pos > &H4000 Then
            f.buffer_len = &H4000
        Else
            f.buffer_len = f.file_len - f.file_pos
            f.buffer = String(f.buffer_len, " ")
        End If
        f.buffer_pos = 0
        Get f.file_num, f.file_pos + 1, f.buffer
    End If
End Function

' Buffered write one byte at a time from a binary file.
Private Sub BinWrite(ByRef f As BinFile, b As Integer)
    Mid(f.buffer, f.buffer_pos + 1, 1) = Chr(b)
    f.buffer_pos = f.buffer_pos + 1
    If f.buffer_pos >= &H4000 Then
        Put f.file_num, , f.buffer
        f.buffer_pos = 0
    End If
End Sub

' Close binary file.
Private Sub BinClose(ByRef f As BinFile)
    If f.mode = "w" And f.buffer_pos > 0 Then
        f.buffer = Left(f.buffer, f.buffer_pos)
        Put f.file_num, , f.buffer
    End If
    Close f.file_num
End Sub

' String builder: Init
Private Function Sb_Init() As String()
    Dim x(-1 To -1) As String
    Sb_Init = x
End Function

' String builder: Clear
Private Sub Sb_Clear(ByRef sb() As String)
    ReDim Sb_Init(-1 To -1)
End Sub

' String builder: Append
Private Sub Sb_Append(ByRef sb() As String, Value As String)
    If LBound(sb) = -1 Then
        ReDim sb(0 To 0)
    Else
        ReDim Preserve sb(0 To UBound(sb) + 1)
    End If
    sb(UBound(sb)) = Value
End Sub

' String builder: Get value
Private Function Sb_Get(ByRef sb() As String) As String
    Sb_Get = Join(sb, "")
End Function

' --------------------------------
' Beginning of main functions of this module
' --------------------------------

' Close all open forms.
Private Function CloseFormsReports()
    On Error GoTo ErrorHandler
    Do While Forms.count > 0
        DoCmd.Close acForm, Forms(0).Name
    Loop
    Do While Reports.count > 0
        DoCmd.Close acReport, Reports(0).Name
    Loop
    Exit Function

ErrorHandler:
    Debug.Print "AppCodeImportExport.CloseFormsReports: Error #" & Err.Number & vbCrLf & Err.Description
End Function

' Pad a string on the right to make it `count` characters long.
Public Function PadRight(Value As String, count As Integer)
    PadRight = Value
    If Len(Value) < count Then
        PadRight = PadRight & Space(count - Len(Value))
    End If
End Function

' Path of the current database file.
Private Function ProjectPath() As String
    ProjectPath = CurrentProject.Path
    If Right(ProjectPath, 1) <> "\" Then ProjectPath = ProjectPath & "\"
End Function

' Path of single temp file used by any function in this module.
Private Function TempFile() As String
    TempFile = ProjectPath() & "AppCodeImportExport.tempdata"
End Function

' Export a database object with optional UCS2-to-UTF-8 conversion.
Private Sub ExportObject(ByVal obj_type_num As AcObjectType, obj_name As String, file_path As String, _
    Optional Ucs2Convert As Boolean = False)

    MkDirIfNotExist Left(file_path, InStrRev(file_path, "\"))
    If Ucs2Convert Then
        Application.SaveAsText obj_type_num, obj_name, TempFile()
        ConvertUcs2Utf8 TempFile(), file_path
    Else
        Application.SaveAsText obj_type_num, obj_name, file_path
    End If
End Sub

' Import a database object with optional UTF-8-to-UCS2 conversion.
Private Sub ImportObject(ByVal obj_type_num As AcObjectType, obj_name As String, file_path As String, _
    Optional Ucs2Convert As Boolean = False)

    If Ucs2Convert Then
        ConvertUtf8Ucs2 file_path, TempFile()
        Application.LoadFromText obj_type_num, obj_name, TempFile()
    Else
        Application.LoadFromText obj_type_num, obj_name, file_path
    End If
End Sub

' Binary convert a UCS2-little-endian encoded file to UTF-8.
Private Sub ConvertUcs2Utf8(source As String, dest As String)
    Dim f_in As BinFile, f_out As BinFile
    Dim in_low As Integer, in_high As Integer

    f_in = BinOpen(source, "r")
    f_out = BinOpen(dest, "w")

    Do While Not f_in.at_eof
        in_low = BinRead(f_in)
        in_high = BinRead(f_in)
        If in_high = 0 And in_low < &H80 Then
            ' U+0000 - U+007F   0LLLLLLL
            BinWrite f_out, in_low
        ElseIf in_high < &H8 Then
            ' U+0080 - U+07FF   110HHHLL 10LLLLLL
            BinWrite f_out, &HC0 + ((in_high And &H7) * &H4) + ((in_low And &HC0) / &H40)
            BinWrite f_out, &H80 + (in_low And &H3F)
        Else
            ' U+0800 - U+FFFF   1110HHHH 10HHHHLL 10LLLLLL
            BinWrite f_out, &HE0 + ((in_high And &HF0) / &H10)
            BinWrite f_out, &H80 + ((in_high And &HF) * &H4) + ((in_low And &HC0) / &H40)
            BinWrite f_out, &H80 + (in_low And &H3F)
        End If
    Loop

    BinClose f_in
    BinClose f_out
End Sub

' Binary convert a UTF-8 encoded file to UCS2-little-endian.
Private Sub ConvertUtf8Ucs2(source As String, dest As String)
    Dim f_in As BinFile, f_out As BinFile
    Dim in_1 As Integer, in_2 As Integer, in_3 As Integer

    f_in = BinOpen(source, "r")
    f_out = BinOpen(dest, "w")

    Do While Not f_in.at_eof
        in_1 = BinRead(f_in)
        If (in_1 And &H80) = 0 Then
            ' U+0000 - U+007F   0LLLLLLL
            BinWrite f_out, in_1
            BinWrite f_out, 0
        ElseIf (in_1 And &HE0) = &HC0 Then
            ' U+0080 - U+07FF   110HHHLL 10LLLLLL
            in_2 = BinRead(f_in)
            BinWrite f_out, ((in_1 And &H3) * &H40) + (in_2 And &H3F)
            BinWrite f_out, (in_1 And &H1C) / &H4
        Else
            ' U+0800 - U+FFFF   1110HHHH 10HHHHLL 10LLLLLL
            in_2 = BinRead(f_in)
            in_3 = BinRead(f_in)
            BinWrite f_out, ((in_2 And &H3) * &H40) + (in_3 And &H3F)
            BinWrite f_out, ((in_1 And &HF) * &H10) + ((in_2 And &H3C) / &H4)
        End If
    Loop

    BinClose f_in
    BinClose f_out
End Sub

' Determine if this database imports/exports code as UCS-2-LE. (Older file
' formats cause exported objects to use a Windows 8-bit character set.)
Private Sub InitUsingUcs2()
    Dim obj_name As String, i As Integer, obj_type As Variant, fn As Integer, bytes As String
    Dim obj_type_split() As String, obj_type_name As String, obj_type_num As Integer
    Dim db As Object ' DAO.Database

    If CurrentDb.QueryDefs.count > 0 Then
        obj_type_num = acQuery
        obj_name = CurrentDb.QueryDefs(0).Name
    Else
        For Each obj_type In Split( _
            "Forms|" & acForm & "," & _
            "Reports|" & acReport & "," & _
            "Scripts|" & acMacro & "," & _
            "Modules|" & acModule _
        )
            obj_type_split = Split(obj_type, "|")
            obj_type_name = obj_type_split(0)
            obj_type_num = Val(obj_type_split(1))
            If CurrentDb.Containers(obj_type_name).Documents.count > 0 Then
                obj_name = CurrentDb.Containers(obj_type_name).Documents(1).Name
                Exit For
            End If
        Next
    End If

    If obj_name = "" Then
        ' No objects found that can be used to test UCS2 versus UTF-8
        UsingUcs2 = True
        Exit Sub
    End If

    Application.SaveAsText obj_type_num, obj_name, TempFile()
    fn = FreeFile
    Open TempFile() For Binary Access Read As fn
    bytes = "  "
    Get fn, 1, bytes
    If Asc(Mid(bytes, 1, 1)) = &HFF And Asc(Mid(bytes, 2, 1)) = &HFE Then
        UsingUcs2 = True
    Else
        UsingUcs2 = False
    End If
    Close fn
End Sub

' Create folder `Path`. Silently do nothing if it already exists.
Private Sub MkDirIfNotExist(Path As String)
    On Error GoTo MkDirIfNotexist_noop
    MkDir Path
MkDirIfNotexist_noop:
    On Error GoTo 0
End Sub

' Delete a file if it exists.
Private Sub DelIfExist(Path As String)
    On Error GoTo DelIfNotExist_Noop
    Kill Path
DelIfNotExist_Noop:
    On Error GoTo 0
End Sub

' Erase all *.`ext` files in `Path`.
Private Sub ClearTextFilesFromDir(Path As String, Ext As String)
    Dim fso As Object
    Set fso = CreateObject("Scripting.FileSystemObject")
    If Not fso.FolderExists(Path) Then Exit Sub

    On Error GoTo ClearTextFilesFromDir_noop
    If Dir(Path & "*." & Ext) <> "" Then
        Kill Path & "*." & Ext
    End If
ClearTextFilesFromDir_noop:

    On Error GoTo 0
End Sub

' For each *.txt in `Path`, find and remove a number of problematic but
' unnecessary lines of VB code that are inserted automatically by the
' Access GUI and change often (we don't want these lines of code in
' version control).
Private Sub SanitizeTextFiles(Path As String, Ext As String)
    Dim fso, InFile, OutFile, FileName As String, txt As String, obj_name As String

    Set fso = CreateObject("Scripting.FileSystemObject")

    FileName = Dir(Path & "*." & Ext)
    Do Until Len(FileName) = 0
        obj_name = Mid(FileName, 1, InStrRev(FileName, ".") - 1)

        Set InFile = fso.OpenTextFile(Path & obj_name & "." & Ext, ForReading)
        Set OutFile = fso.CreateTextFile(Path & obj_name & ".sanitize", True)
        Do Until InFile.AtEndOfStream
            txt = InFile.ReadLine
            If Left(txt, 10) = "Checksum =" Then
                ' Skip lines starting with Checksum
            ElseIf InStr(txt, "NoSaveCTIWhenDisabled =1") Then
                ' Skip lines containning NoSaveCTIWhenDisabled
            ElseIf InStr(txt, "Begin") > 0 Then
                If _
                    InStr(txt, "PrtDevNames =") > 0 Or _
                    InStr(txt, "PrtDevNamesW =") > 0 Or _
                    InStr(txt, "PrtDevModeW =") > 0 Or _
                    InStr(txt, "PrtDevMode =") > 0 _
                    Then

                    ' skip this block of code
                    Do Until InFile.AtEndOfStream
                        txt = InFile.ReadLine
                        If InStr(txt, "End") Then Exit Do
                    Loop
                ElseIf AggressiveSanitize And ( _
                    InStr(txt, "dbLongBinary ""DOL"" =") > 0 Or _
                    InStr(txt, "NameMap") > 0 Or _
                    InStr(txt, "GUID") > 0 _
                    ) Then

                    ' skip this block of code
                    Do Until InFile.AtEndOfStream
                        txt = InFile.ReadLine
                        If InStr(txt, "End") Then Exit Do
                    Loop
                End If
            Else
                OutFile.WriteLine txt
            End If
        Loop
        OutFile.Close
        InFile.Close

        FileName = Dir()
    Loop

    FileName = Dir(Path & "*." & Ext)
    Do Until Len(FileName) = 0
        obj_name = Mid(FileName, 1, InStrRev(FileName, ".") - 1)
        Kill Path & obj_name & "." & Ext
        Name Path & obj_name & ".sanitize" As Path & obj_name & "." & Ext
        FileName = Dir()
    Loop
End Sub

' Main entry point for EXPORT. Export all forms, reports, queries,
' macros, modules, and lookup tables to `source` folder under the
' database's folder.
Public Sub ExportAllSource()
    Dim db As Database 'Object ' DAO.Database
    Dim source_path As String
    Dim obj_path As String
    Dim qry As Object ' DAO.QueryDef
    Dim doc As Object ' DAO.Document
    Dim obj_type As Variant
    Dim obj_type_split() As String
    Dim obj_type_label As String
    Dim obj_type_name As String
    Dim obj_type_num As Integer
    Dim obj_count As Integer
    Dim ucs2 As Boolean
    Dim tblName As Variant

    Set db = CurrentDb

    CloseFormsReports
    InitUsingUcs2

    source_path = ProjectPath() & "source\"
    MkDirIfNotExist source_path

    Debug.Print

    Debug.Print PadRight("Exporting references...", 30);
    Debug.Print "[" & ExportRefsUTF8(source_path & "references\") & "]"

    obj_path = source_path & "queries\"
    ClearTextFilesFromDir obj_path, "bas"
    Debug.Print PadRight("Exporting queries...", 30);
    obj_count = 0
    For Each qry In db.QueryDefs
        If Left(qry.Name, 1) <> "~" Then
            ExportObject acQuery, qry.Name, obj_path & qry.Name & ".bas", UsingUcs2
            obj_count = obj_count + 1
        End If
    Next
    SanitizeTextFiles obj_path, "bas"
    Debug.Print "[" & obj_count & "]"

    obj_path = source_path & "tables\"
    ClearTextFilesFromDir obj_path, "txt"
    
    Dim td As TableDef
    obj_count = 0
    Debug.Print PadRight("Exporting tables...", 30);
    For Each td In CurrentDb.TableDefs

        
        Dim schemaOnly As Boolean
        schemaOnly = True
        
        'check if we need to export the data
        If (Len(Replace(DATA_TABLES, " ", "")) > 0) Then
            For Each tblName In Split(DATA_TABLES, ",")
                If td.Name = tblName Then schemaOnly = False
            Next
        End If
        
        If schemaOnly Then
            'we dont want to export hidden, system or linked objects - unless they are explicitly declared in DATA_TABLES!
            'TableDefAttributeEnum
            'Defs for HiddenObject and SystemObject wrong
            'HiddenObject = 2
            'SystemObject = -2147483648
            If Not (((td.Attributes And 2) = 2) Or ((td.Attributes And -2147483648#) = -2147483648#) _
                Or ((td.Attributes And TableDefAttributeEnum.dbHiddenObject) = TableDefAttributeEnum.dbHiddenObject) _
                Or ((td.Attributes And TableDefAttributeEnum.dbSystemObject) = TableDefAttributeEnum.dbSystemObject)) Then
                    If ((td.Attributes And TableDefAttributeEnum.dbAttachedTable) = TableDefAttributeEnum.dbAttachedTable) _
                        Or ((td.Attributes And TableDefAttributeEnum.dbAttachedODBC) = TableDefAttributeEnum.dbAttachedODBC) Then
                        ExportLinkedTable td.Name, obj_path
                
                    Else
                
                    ExportTableWithoutData td.Name, obj_path
                    obj_count = obj_count + 1
                End If
            End If

        Else
            ExportTableWithData td.Name, obj_path
            obj_count = obj_count + 1
        End If
    
    Next
    Debug.Print "[" & obj_count & "]"

    'There is no list of data macros, so we have to use the list of tables
    For Each obj_type In Split( _
        "forms|Forms|" & acForm & "," & _
        "reports|Reports|" & acReport & "," & _
        "macros|Scripts|" & acMacro & "," & _
        "modules|Modules|" & acModule & "," & _
        "tables\macros|Tables|" & acTableDataMacro, "," _
    )
        obj_type_split = Split(obj_type, "|")
        obj_type_label = obj_type_split(0)
        obj_type_name = obj_type_split(1)
        obj_type_num = Val(obj_type_split(2))
        obj_path = source_path & obj_type_label & "\"
        obj_count = 0
        ClearTextFilesFromDir obj_path, "bas"
        Debug.Print PadRight("Exporting " & obj_type_label & "...", 30);
        For Each doc In db.Containers(obj_type_name).Documents
            If Left(doc.Name, 1) <> "~" Then
                If obj_type_label = "modules" Then
                    ucs2 = False
                Else
                    ucs2 = UsingUcs2
                End If
                'this is very bad - needs proper error handling
                'done for tables that don't have macros - export throws error
                On Error GoTo Err_ExportObj:
                ExportObject obj_type_num, doc.Name, obj_path & doc.Name & ".bas", ucs2
                If obj_type_num = acTableDataMacro Then FormatDataMacro obj_path & doc.Name & ".bas"
                obj_count = obj_count + 1
                GoTo Err_ExportObj_Fin:
Err_ExportObj:
                Resume Err_ExportObj_Fin:
Err_ExportObj_Fin:
                On Error GoTo 0
            End If
        Next
        Debug.Print "[" & obj_count & "]"

        If obj_type_label <> "modules" Then
            SanitizeTextFiles obj_path, "bas"
        End If
    Next

    DelIfExist TempFile()
    Debug.Print "Done."
End Sub

' Main entry point for IMPORT. Import all forms, reports, queries,
' macros, modules, and lookup tables from `source` folder under the
' database's folder.
Public Sub ImportAllSource()
    Dim db As Object ' DAO.Database
    Dim fso As Object
    Dim source_path As String
    Dim obj_path As String
    Dim qry As Object ' DAO.QueryDef
    Dim doc As Object ' DAO.Document
    Dim obj_type As Variant
    Dim obj_type_split() As String
    Dim obj_type_label As String
    Dim obj_type_name As String
    Dim obj_type_num As Integer
    Dim obj_count As Integer
    Dim FileName As String
    Dim obj_name As String
    Dim ucs2 As Boolean

    Set db = CurrentDb
    Set fso = CreateObject("Scripting.FileSystemObject")

    CloseFormsReports
    InitUsingUcs2

    source_path = ProjectPath() & "source\"
    If Not fso.FolderExists(source_path) Then
        MsgBox "No source found at:" & vbCrLf & source_path, vbExclamation, "Import failed"
        Exit Sub
    End If

    Debug.Print

    Debug.Print PadRight("Importing references...", 24);
    Debug.Print "[" & ImportRefsUTF8(source_path & "references\") & "]"

    obj_path = source_path & "queries\"
    FileName = Dir(obj_path & "*.bas")
    If Len(FileName) > 0 Then
        Debug.Print PadRight("Importing queries...", 24);
        obj_count = 0
        Do Until Len(FileName) = 0
            obj_name = Mid(FileName, 1, InStrRev(FileName, ".") - 1)
            ImportObject acQuery, obj_name, obj_path & FileName, UsingUcs2
            obj_count = obj_count + 1
            FileName = Dir()
        Loop
        Debug.Print "[" & obj_count & "]"
    End If

    obj_path = source_path & "tables\"
    FileName = Dir(obj_path & "*.xml")
    Debug.Print PadRight("Importing tables...", 24);
    obj_count = 0
    If Len(FileName) > 0 Then
        Do Until Len(FileName) = 0
            obj_name = Mid(FileName, 1, InStrRev(FileName, ".") - 1)
            ImportTable CStr(obj_name), obj_path
            obj_count = obj_count + 1
            FileName = Dir()
        Loop
    End If
    
    'import linked tables
    FileName = Dir(obj_path & "*.LNKD")
    If Len(FileName) > 0 Then
        Do Until Len(FileName) = 0
            obj_name = Mid(FileName, 1, InStrRev(FileName, ".") - 1)
            ImportLinkedTable CStr(obj_name), obj_path
            obj_count = obj_count + 1
            FileName = Dir()
        Loop
    End If
    
    Debug.Print "[" & obj_count & "]"

    For Each obj_type In Split( _
        "forms|" & acForm & "," & _
        "reports|" & acReport & "," & _
        "macros|" & acMacro & "," & _
        "modules|" & acModule & "," & _
        "tables\macros|" & acTableDataMacro, "," _
    )
        obj_type_split = Split(obj_type, "|")
        obj_type_label = obj_type_split(0)
        obj_type_num = Val(obj_type_split(1))
        obj_path = source_path & obj_type_label & "\"
        FileName = Dir(obj_path & "*.bas")
        If Len(FileName) > 0 Then
            Debug.Print PadRight("Importing " & obj_type_label & "...", 24);
            obj_count = 0
            Do Until Len(FileName) = 0
                obj_name = Mid(FileName, 1, InStrRev(FileName, ".") - 1)
                If obj_name <> "AppCodeImportExport" Then
                    If obj_type_label = "modules" Then
                        ucs2 = False
                    Else
                        ucs2 = UsingUcs2
                    End If
                    ImportObject obj_type_num, obj_name, obj_path & FileName, ucs2
                    obj_count = obj_count + 1
                End If
                FileName = Dir()
            Loop
            Debug.Print "[" & obj_count & "]"
        End If
    Next


    DelIfExist TempFile()
    Debug.Print "Done."
End Sub

' Build SQL to export `tbl_name` sorted by each field from first to last
Public Function TableExportSql(tbl_name As String)
    Dim rs As Object ' DAO.Recordset
    Dim fieldObj As Object ' DAO.Field
    Dim sb() As String, count As Integer

    Set rs = CurrentDb.OpenRecordset(tbl_name)

    sb = Sb_Init()
    Sb_Append sb, "SELECT "
    count = 0
    For Each fieldObj In rs.fields
        If count > 0 Then Sb_Append sb, ", "
        Sb_Append sb, "[" & fieldObj.Name & "]"
        count = count + 1
    Next
    Sb_Append sb, " FROM [" & tbl_name & "] ORDER BY "
    count = 0
    For Each fieldObj In rs.fields
        If count > 0 Then Sb_Append sb, ", "
        Sb_Append sb, "[" & fieldObj.Name & "]"
        count = count + 1
    Next

    TableExportSql = Sb_Get(sb)
End Function

' Export the lookup table `tblName` to `source\tables`.
Private Sub ExportTable(tbl_name As String, obj_path As String)
    Dim fso, OutFile
    Dim rs As Object ' DAO.Recordset
    Dim fieldObj As Object ' DAO.Field
    Dim C As Long, Value As Variant

    Set fso = CreateObject("Scripting.FileSystemObject")
    ' open file for writing with Create=True, Unicode=True (USC-2 Little Endian format)
    MkDirIfNotExist obj_path
    Set OutFile = fso.CreateTextFile(TempFile(), True, True)

    Set rs = CurrentDb.OpenRecordset(TableExportSql(tbl_name))
    C = 0
    For Each fieldObj In rs.fields
        If C <> 0 Then OutFile.Write vbTab
        C = C + 1
        OutFile.Write fieldObj.Name
    Next
    OutFile.Write vbCrLf

    rs.MoveFirst
    Do Until rs.EOF
        C = 0
        For Each fieldObj In rs.fields
            If C <> 0 Then OutFile.Write vbTab
            C = C + 1
            Value = rs(fieldObj.Name)
            If IsNull(Value) Then
                Value = ""
            Else
                Value = Replace(Value, "\", "\\")
                Value = Replace(Value, vbCrLf, "\n")
                Value = Replace(Value, vbCr, "\n")
                Value = Replace(Value, vbLf, "\n")
                Value = Replace(Value, vbTab, "\t")
            End If
            OutFile.Write Value
        Next
        OutFile.Write vbCrLf
        rs.MoveNext
    Loop
    rs.Close
    OutFile.Close

    ConvertUcs2Utf8 TempFile(), obj_path & tbl_name & ".txt"
End Sub

Private Sub ExportTableWithData(tbl_name As String, obj_path As String)
    Application.ExportXML acExportTable, tbl_name, obj_path & tbl_name & ".xml", , , , acUTF8, acEmbedSchema
    SanitizeXML obj_path & tbl_name & ".xml"
End Sub

Private Sub ExportTableWithoutData(tbl_name As String, obj_path As String)
    MkDirIfNotExist (obj_path)
    Application.ExportXML acExportTable, tbl_name, , obj_path & tbl_name & ".xml", , , acUTF8
End Sub

' Import the lookup table `tblName` from `source\tables`.
Private Sub ImportTable(tblName As String, obj_path As String)
    'if there is no data, only the structure is imported
    Application.ImportXML obj_path & tblName & ".xml", acStructureAndData

End Sub

Private Sub SanitizeXML(filePath As String)

    Dim saveStream As Object 'ADODB.Stream

    Set saveStream = CreateObject("ADODB.Stream")
    saveStream.Charset = "utf-8"
    saveStream.LineSeparator = 10 'adLF
    saveStream.Type = 2 'adTypeText
    saveStream.Open

    Dim objStream As Object 'ADODB.Stream
    Dim strData As String
    Set objStream = CreateObject("ADODB.Stream")

    objStream.Charset = "utf-8"
    objStream.LineSeparator = 10 'adLF
    objStream.Type = 2 'adTypeText
    objStream.Open
    objStream.LoadFromFile (filePath)

    Do While objStream.EOS = False
    strData = objStream.ReadText(-2) 'adReadLine
    If InStr(strData, "<dataroot xmlns:xsi=""http://www.w3.org/2001/XMLSchema-instance"" generated=") = 1 Then
        strData = Left(strData, InStr(strData, "generated=") - 2)
        
        If InStrRev(strData, "/>") > 0 Then
            strData = Left(strData, InStr(strData, "generated=") - 2)
            strData = strData & "/>" & Chr(&HD)
        Else
            strData = Left(strData, InStr(strData, "generated=") - 2)
            'add Chr(&HD) - adds Carriage Return - file has CRLF as line but stream wont take this as a lineSperator option
            strData = strData & ">" & Chr(&HD)
        End If
        
        saveStream.WriteText strData, 1 'adWriteLine
    Else
        'adWriteLine or LF will be missed off - line seperator removed when line is read
        saveStream.WriteText strData, 1 'adWriteLine
    End If

    Loop
    objStream.Close
    saveStream.SaveToFile filePath, 2 'adSaveCreateOverWrite
    saveStream.Close

End Sub

'Splits exported DataMacro XML onto multiple lines
'Allows git to find changes within lines using diff
Private Sub FormatDataMacro(filePath As String)

    Dim saveStream As Object 'ADODB.Stream

    Set saveStream = CreateObject("ADODB.Stream")
    saveStream.Charset = "utf-8"
    saveStream.Type = 2 'adTypeText
    saveStream.Open

    Dim objStream As Object 'ADODB.Stream
    Dim strData As String
    Set objStream = CreateObject("ADODB.Stream")

    objStream.Charset = "utf-8"
    objStream.Type = 2 'adTypeText
    objStream.Open
    objStream.LoadFromFile (filePath)
    
    Do While Not objStream.EOS
        strData = objStream.ReadText(-2) 'adReadLine

        Dim tag As Variant
        
        For Each tag In Split(strData, ">")
            If tag <> "" Then
                saveStream.WriteText tag & ">", 1 'adWriteLine
            End If
        Next
        
    Loop
    
    objStream.Close
    saveStream.SaveToFile filePath, 2 'adSaveCreateOverWrite
    saveStream.Close

End Sub

Public Sub ImportLinkedTable(tblName As String, obj_path As String)
    Dim db As Database ' DAO.Database
    Dim fso, InFile As Object
    
    Set db = CurrentDb
    Set fso = CreateObject("Scripting.FileSystemObject")
    
    ConvertUtf8Ucs2 obj_path & tblName & ".LNKD", TempFile()
    ' open file for reading with Create=False, Unicode=True (USC-2 Little Endian format)
    Set InFile = fso.OpenTextFile(TempFile(), ForReading, False, TristateTrue)
    
    On Error GoTo err_notable:
    DoCmd.DeleteObject acTable, tblName
    
    GoTo err_notable_fin:
err_notable:
    Err.Clear
    Resume err_notable_fin:
err_notable_fin:
    On Error GoTo Err_CreateLinkedTable:
    
    Dim td As TableDef
    Set td = db.CreateTableDef(InFile.ReadLine())
    td.Connect = InFile.ReadLine()
    td.SourceTableName = InFile.ReadLine()
    db.TableDefs.Append td
    
    GoTo Err_CreateLinkedTable_Fin:
    
Err_CreateLinkedTable:
    MsgBox Err.Description, vbCritical, "ERROR: IMPORT LINKED TABLE"
    Resume Err_CreateLinkedTable_Fin:
Err_CreateLinkedTable_Fin:

    'this will throw errors if a primary key already exists or the table is linked to an access database table
    'will also error out if no pk is present
    On Error GoTo Err_LinkPK_Fin:
    
    Dim fields As String
    fields = InFile.ReadLine()
    Dim field As Variant
    Dim sql As String
    sql = "CREATE INDEX __uniqueindex ON " & td.Name & " ("
    
    For Each field In Split(fields, ";+")
        sql = sql & "[" & field & "]" & ","
    Next
    'remove extraneous comma
    sql = Left(sql, Len(sql) - 1)
    
    sql = sql & ") WITH PRIMARY"
    CurrentDb.Execute sql
    
Err_LinkPK_Fin:
    
    InFile.Close
    
   

End Sub

Public Sub ExportLinkedTable(tbl_name As String, obj_path As String)
    On Error GoTo Err_LinkedTable:
    
    Dim fso, OutFile

    Set fso = CreateObject("Scripting.FileSystemObject")
    ' open file for writing with Create=True, Unicode=True (USC-2 Little Endian format)
    MkDirIfNotExist obj_path
    Set OutFile = fso.CreateTextFile(TempFile(), True, True)

    OutFile.Write CurrentDb.TableDefs(tbl_name).Name
    OutFile.Write vbCrLf
    OutFile.Write CurrentDb.TableDefs(tbl_name).Connect
    OutFile.Write vbCrLf
    OutFile.Write CurrentDb.TableDefs(tbl_name).SourceTableName
    OutFile.Write vbCrLf
    

    Dim db As Database
    Set db = CurrentDb
    Dim td As TableDef
    Set td = db.TableDefs(tbl_name)
    Dim idx As Index
    
    For Each idx In td.Indexes
        If idx.Primary Then
            OutFile.Write Right(idx.fields, Len(idx.fields) - 1)
            OutFile.Write vbCrLf
        End If

    Next
    

Err_LinkedTable_Fin:

    OutFile.Close
    'save files as .odbc
    ConvertUcs2Utf8 TempFile(), obj_path & tbl_name & ".LNKD"
    
    Exit Sub
    
Err_LinkedTable:

    OutFile.Close
    MsgBox Err.Description, vbCritical, "ERROR: EXPORT LINKED TABLE"
    Resume Err_LinkedTable_Fin:
End Sub


Public Function AddRef(refPath As String) As Boolean

On Error GoTo Err_AddRef:
    Application.References.AddFromFile refPath
    AddRef = True
    Exit Function
Err_AddRef:
    '32813 is a duplicate entry error - we expect to see this for the default libraries as they will already be present
    If Err.Number <> 32813 Then
        Debug.Print "Failed to add reference: " & refPath
        Debug.Print Err.Description
    End If
    AddRef = False
End Function

'Exports references and returns a count of the references exported
Private Function ExportRefsUTF8(filePath As String) As Integer
    MkDirIfNotExist filePath

    ExportRefsUTF8 = 0
    
    Dim saveStream As Object 'ADODB.Stream

    Set saveStream = CreateObject("ADODB.Stream")
    saveStream.Charset = "utf-8"
    saveStream.Type = 2 'adTypeText
    saveStream.Open
    
    Dim ref As Reference

    For Each ref In Application.References
        saveStream.WriteText ref.FullPath, 1 'adWriteLine
        ExportRefsUTF8 = ExportRefsUTF8 + 1
    Next

    saveStream.SaveToFile filePath & "references.txt", 2 'adSaveCreateOverWrite
    saveStream.Close

End Function

Private Function ImportRefsUTF8(filePath As String) As Integer
    ImportRefsUTF8 = 0
    Dim objStream As Object 'ADODB.Stream
    Dim strData As String
    Set objStream = CreateObject("ADODB.Stream")

    objStream.Charset = "utf-8"
    objStream.Type = 2 'adTypeText
    objStream.Open
    objStream.LoadFromFile (filePath & "references.txt")
    
    Do While Not objStream.EOS
        strData = objStream.ReadText(-2) 'adReadLine

        If AddRef(strData) Then ImportRefsUTF8 = ImportRefsUTF8 + 1
    Loop
    
    objStream.Close

End Function

Public Sub testExportObject(obj_type_num As AcObjectType, obj_name As String, file_path As String, _
    Optional Ucs2Convert As Boolean = False)
    ExportObject obj_type_num, obj_name, file_path & obj_name & ".bas", Ucs2Convert
    
    If obj_type_num <> acModule Then
        SanitizeTextFiles file_path, "bas"
    End If


    DelIfExist TempFile()

End Sub

Public Sub testImportObject(obj_type_num As AcObjectType, obj_name As String, file_path As String, _
    Optional Ucs2Convert As Boolean = False)
    ImportObject obj_type_num, obj_name, file_path, Ucs2Convert

    DelIfExist TempFile()
    
End Sub

