unit xeElements;

interface

uses
  Classes,
  //xedit units
  wbInterface,
  // xelib units
  xeMeta;

type
  TSmashType = ( stUnknown, stRecord, stString, stInteger, stFlag, stFloat,
    stStruct, stUnsortedArray, stUnsortedStructArray, stSortedArray,
    stSortedStructArray, stByteArray, stUnion );
  TSmashTypes = set of TSmashType;

  function GetElement(_id: Cardinal; key: PWideChar; _res: PCardinal): WordBool; cdecl;
  function GetElements(_id: Cardinal; len: PInteger): WordBool; cdecl;
  function GetElementFile(_id: Cardinal; _res: PCardinal): WordBool; cdecl;
  function GetContainer(_id: Cardinal; _res: PCardinal): WordBool; cdecl;
  function AddElement(_id: Cardinal; key: PWideChar; _res: PCardinal): WordBool; cdecl;
  function RemoveElement(_id: Cardinal; key: PWideChar): WordBool; cdecl;
  function GetLinksTo(_id: Cardinal; key: PWideChar; _res: PCardinal): WordBool; cdecl;
  function ElementExists(_id: Cardinal; key: PWideChar; bool: PWordBool): WordBool; cdecl;
  function ElementCount(_id: Cardinal; count: PInteger): WordBool; cdecl;
  function ElementEquals(_id, _id2: Cardinal; bool: PWordBool): WordBool; cdecl;
  function CopyElement(_id, _id2: Cardinal; aAsNew, aDeepCopy: WordBool; _res: PCardinal): WordBool; cdecl;

  // native functions
  function ResolveFromGroup(group: IwbGroupRecord; path: String): IInterface;
  function ResolveElement(e: IInterface; path: String): IInterface;
  function NativeGetElement(_id: Cardinal; key: PWideChar): IInterface;
  procedure NativeMoveToIndex(element: IwbElement; index: Integer);
  function NativeContainer(element: IwbElement): IwbContainer;
  function NativeAddElement(_id: Cardinal; key: string): IInterface;
  function IsArray(element: IwbElement): Boolean;
  function GetDefType(element: IwbElement): TwbDefType;
  function GetSmashType(element: IwbElement): TSmashType;

implementation

uses
  Variants, SysUtils,
  // mte units
  mteHelpers,
  // xedit units
  wbImplementation,
  // xelib units
  xeMessages, xeFiles, xeGroups, xeSetup;

{******************************************************************************}
{ ELEMENT HANDLING
  Methods for handling elements: groups, records, and subrecords.
}
{******************************************************************************}

function ParseIndex(key: string; var index: Integer): Boolean;
begin
  Result := (key[1] = '[') and (key[Length(key)] = ']');
  if Result then
    index := StrToInt(Copy(key, 2, Length(key) - 2));
end;

function IsHexStr(key: String): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 1 to Length(key) do
    if not CharInSet(key[i], ['A'..'F','0'..'9']) then exit;
  Result := True;
end;

function ParseFormID(key: String; var formID: Cardinal): Boolean;
begin
  Result := (Length(key) = 8) and IsHexStr(key);
  if Result then
    formID := StrToInt('$' + key);
end;

procedure SplitPath(path: String; var key, nextPath: String);
var
  i: Integer;
begin
  i := Pos('\', path);
  if i > 0 then begin
    key := Copy(path, 1, i - 1);
    nextPath := Copy(path, i + 1, Length(path));
  end
  else
    key := path;
end;

function ResolveByIndex(container: IwbContainerElementRef; index: Integer; nextPath: String): IInterface;
var
  element: IwbElement;
begin
  // resolve element from container if container present
  // else resolve file at index
  if Assigned(container) and (index < container.ElementCount) then
    element := container.Elements[index]
  else
    element := NativeFileByIndex(index);

  // resolve next element if nextPath is present
  // else store the element and return it
  if Assigned(element) and (Length(nextPath) > 0) then
    Result := ResolveElement(element, nextPath)
  else
    Result := element;
end;

function ResolveRecord(_file: IwbFile; formID: Cardinal; path: String): IInterface;
var
  rec: IwbMainRecord;
begin
  rec := _file.RecordByFormID[formID, True];
  if Assigned(rec) and (Length(path) > 0) then
    Result := ResolveElement(rec, path)
  else
    Result := rec;
end;

function ResolveChildGroup(rec: IwbMainRecord; nextPath: String): IInterface;
var
  group: IwbGroupRecord;
begin
  group := rec.ChildGroup;
  if Length(nextPath) > 0 then
    Result := ResolveFromGroup(group, nextPath)
  else
    Result := group;
end;

function ResolveGroup(_file: IwbFile; sig: TwbSignature; nextPath: String): IInterface;
var
  group: IwbGroupRecord;
begin
  // TODO: perhaps also by group name?
  group := _file.GroupBySignature[sig];
  if Assigned(group) and (Length(nextPath) > 0) then
    Result := ResolveElement(group, nextPath)
  else
    Result := group;
end;

function ResolveFile(fileName, nextPath: String): IInterface;
var
  _file: IwbFile;
begin
  _file := NativeFileByName(fileName);
  if Assigned(_file) and (Length(nextPath) > 0) then
    Result := ResolveElement(_file, nextPath)
  else
    Result := _file;
end;

function ResolveFromContainer(container: IwbContainerElementRef; path: String): IInterface;
begin
  Result := container.ElementByPath[path];
end;

function ResolveFromRecord(rec: IwbMainRecord; path: String): IInterface;
var
  key, nextPath: String;
  container: IwbContainerElementRef;
begin
  Result := nil;
  SplitPath(path, key, nextPath);
  if SameText(key, 'Child Group') then
    Result := ResolveChildGroup(rec, nextPath)
  else if Supports(rec, IwbContainerElementRef, container) then
    Result := ResolveFromContainer(container, path);
end;

function ResolveFromGroup(group: IwbGroupRecord; path: String): IInterface;
var
  key, nextPath: String;
  index: Integer;
  formID: Cardinal;
begin
  Result := nil;
  SplitPath(path, key, nextPath);
  // resolve record by index if key is an index
  // else resolve record by formID
  if ParseIndex(key, index) then
    Result := ResolveByIndex(group as IwbContainerElementRef, index, nextPath)
  else if ParseFormID(key, formID) then
    Result := ResolveRecord(group._File, formID, nextPath);
end;

function ResolveFromFile(_file: IwbFile; path: String): IInterface;
var
  key, nextPath: String;
  index: Integer;
  formID: Cardinal;
begin
  SplitPath(path, key, nextPath);
  // resolve group by index if key is an index
  // else resolve record by formID if key is a formID
  // else resolve by group signature
  if ParseIndex(key, index) then
    Result := ResolveByIndex(_file as IwbContainerElementRef, index, nextPath)
  else if ParseFormID(key, formID) then
    Result := ResolveRecord(_file, formID, nextPath)
  else 
    Result := ResolveGroup(_file, StrToSignature(key), nextPath);
end;

function ResolveFromRoot(path: String): IInterface;
var
  key, nextPath: String;
  index: Integer;
begin
  SplitPath(path, key, nextPath);
  // resolve file by index if key is an index
  // else resolve by file name
  if ParseIndex(key, index) then
    Result := ResolveByIndex(nil, index, nextPath)
  else 
    Result := ResolveFile(key, nextPath);
end;

function ResolveElement(e: IInterface; path: String): IInterface;
var
  _file: IwbFile;
  group: IwbGroupRecord;
  rec: IwbMainRecord;
  container: IwbContainerElementRef;
begin
  Result := nil;
  if Supports(e, IwbFile, _file) then
    Result := ResolveFromFile(_file, path)
  else if Supports(e, IwbGroupRecord, group) then
    Result := ResolveFromGroup(group, path)
  else if Supports(e, IwbMainRecord, rec) then
    Result := ResolveFromRecord(rec, path)
  else if Supports(e, IwbContainerElementRef, container) then
    Result := ResolveFromContainer(container, path);
end;

function NativeGetElement(_id: Cardinal; key: PWideChar): IInterface;
begin
  if string(key) = '' then
    Result := Resolve(_id)
  else if _id = 0 then
    Result := ResolveFromRoot(string(key))
  else
    Result := ResolveElement(Resolve(_id), string(key));
end;

// Replaces ElementByName, ElementByPath, ElementByIndex, GroupBySignature, and
// ElementBySignature.  Supports indexed paths.
function GetElement(_id: Cardinal; key: PWideChar; _res: PCardinal): WordBool; cdecl;
var
  e: IInterface;
begin
  Result := False;
  try
    e := NativeGetElement(_id, key);
    if Assigned(e) then begin
      _res^ := Store(e);
      Result := True;
    end;
  except
    on x: Exception do ExceptionHandler(x);
  end;
end;

function GetFiles(len: PInteger): WordBool;
var
  i: Integer;
begin
  len^ := High(xFiles) + 1;
  SetLength(resultArray, len^);
  for i := 0 to High(xFiles) do
    resultArray[i] := Store(xFiles[i]);
  Result := True;
end;

function GetChildrenElements(_id: Cardinal; len: PInteger): WordBool;
var
  i: Integer;
  container: IwbContainerElementRef;
begin
  Result := False;
  if Supports(Resolve(_id), IwbContainerElementRef, container) then begin
    len^ := container.ElementCount;
    SetLength(resultArray, len^);
    for i := 0 to Pred(container.ElementCount) do
      resultArray[i] := Store(container.Elements[i]);
    Result := True;
  end;
end;

// returns an array of handles for the elements in a container
function GetElements(_id: Cardinal; len: PInteger): WordBool; cdecl;
begin
  Result := False;
  try
    if _id = 0 then
      Result := GetFiles(len)
    else
      Result := GetChildrenElements(_id, len);
  except
    on x: Exception do ExceptionHandler(x);
  end;
end;

function GetElementFile(_id: Cardinal; _res: PCardinal): WordBool; cdecl;
var
  element: IwbElement;
begin
  Result := False;
  try
    if Supports(Resolve(_id), IwbElement, element) then begin
      _res^ := Store(element._File);
      Result := True;
    end;
  except
    on x: Exception do ExceptionHandler(x);
  end;
end;

procedure NativeMoveToIndex(element: IwbElement; index: Integer);
var
  container: IwbContainerElementRef;
begin
  container := element.Container as IwbContainerElementRef;
  if index > container.IndexOf(element) then
    Dec(index);
  element.Remove;
  container.InsertElement(index, element);
end;

function NativeContainer(element: IwbElement): IwbContainer;
var
  group: IwbGroupRecord;
begin
  if Supports(element, IwbGroupRecord, group) and IsChildGroup(group) then
    Result := group.ChildrenOf as IwbContainer
  else
    Result := element.Container;
  if not Assigned(Result) then
    raise Exception.Create('Could not find container for ' + element.Name);
end;

function GetContainer(_id: Cardinal; _res: PCardinal): WordBool; cdecl;
var
  e: IInterface;
  element: IwbElement;
begin
  Result := False;
  try
    e := Resolve(_id);
    if not Supports(e, IwbFile) and Supports(e, IwbElement, element) then begin
      _res^ := Store(NativeContainer(element));
      Result := True;
    end;
  except
    on x: Exception do ExceptionHandler(x);
  end;
end;

function NativeAddElement(_id: Cardinal; key: string): IInterface;
var
  e: IInterface;
  _file: IwbFile;
  group: IwbGroupRecord;
  container: IwbContainerElementRef;
  keyIndex: Integer;
begin
  if _id = 0 then begin
    Result := NativeFileByName(key);
    if not Assigned(Result) then
      Result := NativeAddFile(key);
  end
  else begin
    e := Resolve(_id);
    if not Supports(e, IwbContainerElementRef, container) then exit;
    if Supports(e, IwbFile, _file) then
      Result := AddGroupIfMissing(_file, key)
    else if Supports(e, IwbGroupRecord, group) then
      Result := group.Add(key) // TODO: Handle Temporary/Persistent groups?
    else begin
      // no key means we're assigning an element at the end of the array
      if Length(key) = 0 then
        Result := container.Assign(High(integer), nil, False)
      else begin
        // assign element at given index if index given, else add
        if ParseIndex(key, keyIndex) then begin
          Result := container.Assign(High(integer), nil, False);
          NativeMoveToIndex(Result as IwbElement, keyIndex);
        end
        else
          Result := container.Add(key, True);
      end;
    end;
  end;
end;

// replaces ElementAssign, Add, AddElement, and InsertElement
function AddElement(_id: Cardinal; key: PWideChar; _res: PCardinal): WordBool; cdecl;
var
  element: IInterface;
begin
  Result := False;
  try
    element := NativeAddElement(_id, string(key));
    if Assigned(element) then begin
      _res^ := Store(element);
      Result := True;
    end;
  except
    on x: Exception do ExceptionHandler(x);
  end;
end;

function RemoveElement(_id: Cardinal; key: PWideChar): WordBool; cdecl;
var
  e: IInterface;
  element: IwbElement;
begin
  Result := False;
  try
    e := NativeGetElement(_id, key);
    if Supports(e, IwbElement, element) then begin
      element.Remove;
      Result := True;
    end;
  except
    on x: Exception do ExceptionHandler(x);
  end;
end;

function GetLinksTo(_id: Cardinal; key: PWideChar; _res: PCardinal): WordBool; cdecl;
var
  e: IInterface;
  element, linkedElement: IwbElement;
begin
  Result := False;
  try
    e := NativeGetElement(_id, key);
    if Supports(e, IwbElement, element) then begin
      linkedElement := element.LinksTo;
      if Assigned(linkedElement) then begin
        _res^ := Store(linkedElement);
        Result := True;
      end;
    end;
  except
    on x: Exception do ExceptionHandler(x);
  end;
end;

function ElementExists(_id: Cardinal; key: PWideChar; bool: PWordBool): WordBool; cdecl;
var
  e: IInterface;
begin
  Result := False;
  try
    e := NativeGetElement(_id, key);
    bool^ := Assigned(e);
    Result := True;
  except
    on x: Exception do ExceptionHandler(x);
  end;
end;

function ElementCount(_id: Cardinal; count: PInteger): WordBool; cdecl;
var
  container: IwbContainerElementRef;
begin
  Result := False;
  try
    if _id = 0 then begin
      count^ := High(xFiles) + 1;
      Result := True;
    end
    else if Supports(Resolve(_id), IwbContainerElementRef, container) then begin
      count^ := container.ElementCount;
      Result := True;
    end;
  except
    on x: Exception do ExceptionHandler(x);
  end;
end;

function ElementEquals(_id, _id2: Cardinal; bool: PWordBool): WordBool; cdecl;
var
  element, element2: IwbElement;
begin
  Result := False;
  try
    if Supports(Resolve(_id), IwbElement, element) then
      if Supports(Resolve(_id2), IwbElement, element2) then begin
        bool^ := element.Equals(element2);
        Result := True;
      end;
  except
    on x: Exception do ExceptionHandler(x);
  end;
end;

function CopyElement(_id, _id2: Cardinal; aAsNew, aDeepCopy: WordBool; _res: PCardinal): WordBool; cdecl;
var
  _file: IwbFile;
  rec: IwbMainRecord;
  element: IwbElement;
begin
  Result := False;
  try
    if not Supports(Resolve(_id), IwbElement, element) then exit;
    if Supports(Resolve(_id2), IwbFile, _file) then begin
      _res^ := Store(wbCopyElementToFile(element, _file, aAsNew, aDeepCopy, '', '', ''));
      Result := True;
    end
    else if Supports(Resolve(_id2), IwbMainRecord, rec) then begin
      _res^ := Store(wbCopyElementToRecord(element, rec, aAsNew, aDeepCopy));
      Result := True;
    end;
  except
    on x: Exception do ExceptionHandler(x);
  end;
end;

{ Returns true if @e is a sorted container }
function IsSorted(e: IwbElement): boolean;
var
  Container: IwbSortableContainer;
begin
  Result := False;
  if Supports(e, IwbSortableContainer, Container) then
    Result := Container.Sorted;
end;

{ Returns true if @e is a container with struct children }
function HasStructChildren(e: IwbElement): boolean;
var
  Container: IwbContainerElementRef;
begin
  Result := False;
  if Supports(e, IwbContainerElementRef, Container)
  and (Container.ElementCount > 0) then
    Result := GetSmashType(Container.Elements[0]) = stStruct;
end;

function IsArray(element: IwbElement): Boolean;
begin
  Result := GetDefType(element) in [dtSubRecordArray, dtArray];
end;

function GetDefType(element: IwbElement): TwbDefType;
var
  subDef: IwbSubRecordDef;
begin
  if Supports(element.Def, IwbSubRecordDef, subDef) then
    Result := subDef.Value.DefType
  else
    Result := element.Def.DefType;
end;

function GetSmashType(element: IwbElement): TSmashType;
var
  subDef: IwbSubRecordDef;
  dt: TwbDefType;
  bIsSorted, bHasStructChildren: boolean;
begin
  dt := element.Def.DefType;
  if Supports(element.Def, IwbSubRecordDef, subDef) then
    dt := subDef.Value.DefType;

  case Ord(dt) of
    Ord(dtRecord): Result := stRecord;
    Ord(dtSubRecord): Result := stUnknown;
    Ord(dtSubRecordStruct): Result := stStruct;
    Ord(dtSubRecordUnion): Result := stUnion;
    Ord(dtString): Result := stString;
    Ord(dtLString): Result := stString;
    Ord(dtLenString): Result := stString;
    Ord(dtByteArray): Result := stByteArray;
    Ord(dtInteger): Result := stInteger;
    Ord(dtIntegerFormater): Result := stInteger;
    Ord(dtIntegerFormaterUnion): Result := stInteger;
    Ord(dtFlag): Result := stFlag;
    Ord(dtFloat): Result := stFloat;
    Ord(dtSubRecordArray), Ord(dtArray): begin
      bIsSorted := IsSorted(element);
      bHasStructChildren := HasStructChildren(element);
      if bIsSorted then begin
        if bHasStructChildren then
          Result := stSortedStructArray
        else
          Result := stSortedArray;
      end
      else begin
        if bHasStructChildren then
          Result := stUnsortedStructArray
        else
          Result := stUnsortedArray;
      end;
    end;
    Ord(dtStruct): Result := stStruct;
    Ord(dtUnion): Result := stUnion;
    Ord(dtEmpty): Result := stUnknown;
    Ord(dtStructChapter): Result := stStruct;
    else Result := stUnknown;
  end;
end;

end.
