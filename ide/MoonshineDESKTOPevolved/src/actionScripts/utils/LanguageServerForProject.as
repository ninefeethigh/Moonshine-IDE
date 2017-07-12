////////////////////////////////////////////////////////////////////////////////
// Copyright 2016 Prominic.NET, Inc.
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// 
// http://www.apache.org/licenses/LICENSE-2.0 
// 
// Unless required by applicable law or agreed to in writing, software 
// distributed under the License is distributed on an "AS IS" BASIS, 
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and 
// limitations under the License
// 
// Author: Prominic.NET, Inc.
// No warranty of merchantability or fitness of any kind. 
// Use this software at your own risk.
////////////////////////////////////////////////////////////////////////////////
package actionScripts.utils
{
	import actionScripts.ui.IContentWindow;
	import actionScripts.ui.editor.ActionScriptTextEditor;

	import flash.desktop.NativeProcess;
	import flash.desktop.NativeProcessStartupInfo;
	import flash.events.DataEvent;
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.events.NativeProcessExitEvent;
	import flash.events.ProgressEvent;
	import flash.events.SecurityErrorEvent;
	import flash.filesystem.File;
	import flash.net.ServerSocket;
	import flash.net.XMLSocket;
	import flash.utils.Dictionary;
	import flash.utils.IDataInput;

	import actionScripts.events.CompletionItemsEvent;
	import actionScripts.events.DiagnosticsEvent;
	import actionScripts.events.GlobalEventDispatcher;
	import actionScripts.events.GotoDefinitionEvent;
	import actionScripts.events.HoverEvent;
	import actionScripts.events.ProjectEvent;
	import actionScripts.events.ReferencesEvent;
	import actionScripts.events.RenameEvent;
	import actionScripts.events.SignatureHelpEvent;
	import actionScripts.events.SymbolsEvent;
	import actionScripts.events.TypeAheadEvent;
	import actionScripts.factory.FileLocation;
	import actionScripts.locator.IDEModel;
	import actionScripts.plugin.actionscript.as3project.vo.AS3ProjectVO;
	import actionScripts.plugin.actionscript.as3project.vo.BuildOptions;
	import actionScripts.plugin.console.ConsoleOutputter;
	import actionScripts.ui.editor.BasicTextEditor;
	import actionScripts.ui.menu.MenuPlugin;
	import actionScripts.valueObjects.Command;
	import actionScripts.valueObjects.CompletionItem;
	import actionScripts.valueObjects.Diagnostic;
	import actionScripts.valueObjects.Location;
	import actionScripts.valueObjects.ParameterInformation;
	import actionScripts.valueObjects.Position;
	import actionScripts.valueObjects.Range;
	import actionScripts.valueObjects.Settings;
	import actionScripts.valueObjects.SignatureHelp;
	import actionScripts.valueObjects.SignatureInformation;
	import actionScripts.valueObjects.SymbolInformation;
	import actionScripts.valueObjects.TextEdit;

	import mx.collections.ArrayCollection;

	import no.doomsday.console.ConsoleUtil;

	public class LanguageServerForProject
	{
		private static const MARKDOWN_NEXTGENAS_START:String = "```nextgenas\n";
		private static const MARKDOWN_MXML_START:String = "```mxml\n";
		private static const MARKDOWN_CODE_END:String = "\n```";

		private var _project:AS3ProjectVO;
		private var _requestID:int = 0;
		private var _port:int;
		private var _gotoDefinitionLookup:Dictionary = new Dictionary();
		private var _findReferencesLookup:Dictionary = new Dictionary();
		private var _model:IDEModel = IDEModel.getInstance();
		private var _dispatcher:GlobalEventDispatcher = GlobalEventDispatcher.getInstance();
		private var _xmlSocket:XMLSocket;
		private var _shellInfo:NativeProcessStartupInfo;
		private var _nativeProcess:NativeProcess;
		private var _cmdFile:File;
		private var _javaPath:File;
		private var _connected:Boolean = false;
		private var _initialized:Boolean = false;
		private var _previousActiveFilePath:String = null;
		private var _previousActiveResult:Boolean = false;

		public function LanguageServerForProject(project:AS3ProjectVO, javaPath:String)
		{
			_javaPath = new File(javaPath);

			var javaFileName:String = (Settings.os == "win") ? "java.exe" : "java";
			_cmdFile = _javaPath.resolvePath(javaFileName);
			if(!_cmdFile.exists)
			{
				_cmdFile = _javaPath.resolvePath("bin/" + javaFileName);
			}

			_project = project;
			_project.addEventListener(AS3ProjectVO.CHANGE_CUSTOM_SDK, projectChangeCustomSDKHandler);
			_dispatcher.addEventListener(ProjectEvent.REMOVE_PROJECT, removeProjectHandler);
			_dispatcher.addEventListener(TypeAheadEvent.EVENT_DIDOPEN, didOpenCall);
			_dispatcher.addEventListener(TypeAheadEvent.EVENT_DIDCHANGE, didChangeCall);
			_dispatcher.addEventListener(TypeAheadEvent.EVENT_TYPEAHEAD, completionHandler);
			_dispatcher.addEventListener(TypeAheadEvent.EVENT_SIGNATURE_HELP, signatureHelpHandler);
			_dispatcher.addEventListener(TypeAheadEvent.EVENT_HOVER, hoverHandler);
			_dispatcher.addEventListener(TypeAheadEvent.EVENT_GOTO_DEFINITION, gotoDefinitionHandler);
			_dispatcher.addEventListener(TypeAheadEvent.EVENT_WORKSPACE_SYMBOLS, workspaceSymbolsHandler);
			_dispatcher.addEventListener(TypeAheadEvent.EVENT_DOCUMENT_SYMBOLS, documentSymbolsHandler);
			_dispatcher.addEventListener(TypeAheadEvent.EVENT_FIND_REFERENCES, findReferencesHandler);
			_dispatcher.addEventListener(TypeAheadEvent.EVENT_RENAME, renameHandler);
			_dispatcher.addEventListener(MenuPlugin.CHANGE_MENU_SDK_STATE, changeMenuSDKStateHandler);
			_dispatcher.addEventListener(MenuPlugin.MENU_QUIT_EVENT, shutdownHandler);
			//when adding new listeners, don't forget to also remove them in
			//removeProjectHandler()

			_port = findOpenPort();
			startNativeProcess();
		}

		public function get project():AS3ProjectVO
		{
			return _project;
		}

		private function getNextRequestID():int
		{
			_requestID++;
			return _requestID;
		}

		private function isActiveEditorInProject():Boolean
		{
			var editor:BasicTextEditor = _model.activeEditor as BasicTextEditor;
			if(!editor)
			{
				return false;
			}
			return isEditorInProject(editor);
		}

		private function isEditorInProject(editor:BasicTextEditor):Boolean
		{
			var nativePath:String = editor.currentFile.fileBridge.nativePath;
			if(_previousActiveFilePath === nativePath)
			{
				//optimization: don't check this path multiple times when we
				//probably already know the result from last time.
				return _previousActiveResult;
			}
			_previousActiveFilePath = nativePath;
			_previousActiveResult = false;
			var activeFile:File = new File(nativePath);
			var projectFile:File = new File(_project.folderPath);
			//getRelativePath() will return null if activeFile is not in the
			//projectFile directory
			if(projectFile.getRelativePath(activeFile, false) !== null)
			{
				_previousActiveResult = true;
				return _previousActiveResult;
			}
			var sourcePaths:Vector.<FileLocation> = _project.classpaths;
			var sourcePathCount:int = sourcePaths.length;
			for(var i:int = 0; i < sourcePathCount; i++)
			{
				var sourcePath:FileLocation = sourcePaths[i];
				var sourcePathFile:File = new File(sourcePath.fileBridge.nativePath);
				if(sourcePathFile.getRelativePath(activeFile, false) !== null)
				{
					_previousActiveResult = true;
					return _previousActiveResult;
				}
			}
			return _previousActiveResult;
		}

		private function parseSymbolInformation(original:Object):SymbolInformation
		{
			var vo:SymbolInformation = new SymbolInformation();
			vo.name = original.name;
			vo.kind = original.kind;
			vo.location = parseLocation(original.location);
			return vo;
		}

		private function parseDiagnostic(path:String, original:Object):Diagnostic
		{
			var vo:Diagnostic = new Diagnostic();
			vo.path = path;
			vo.message = original.message;
			vo.code = original.code;
			vo.range = parseRange(original.range);
			vo.severity = original.severity;
			return vo;
		}

		private function parseLocation(original:Object):Location
		{
			var vo:Location = new Location();
			vo.uri = original.uri;
			vo.range = parseRange(original.range);
			return vo;
		}

		private function parseRange(original:Object):Range
		{
			var vo:Range = new Range();
			vo.start = parsePosition(original.start);
			vo.end = parsePosition(original.end);
			return vo;
		}

		private function parsePosition(original:Object):Position
		{
			var vo:Position = new Position();
			vo.line = original.line;
			vo.character = original.character;
			return vo;
		}

		private function parseCompletionItem(original:Object):CompletionItem
		{
			var vo:CompletionItem = new CompletionItem();
			vo.label = original.label;
			vo.insertText = original.insertText;
			vo.detail  = original.detail;
			vo.kind = original.kind;
			if("command" in original)
			{
				vo.command = parseCommand(original.command);
			}
			return vo;
		}

		private function parseCommand(original:Object):Command
		{
			var vo:Command = new Command();
			vo.title = original.title;
			vo.command = original.command;
			vo.arguments = original.arguments;
			return vo;
		}

		private function parseSignatureInformation(original:Object):SignatureInformation
		{
			var vo:SignatureInformation = new SignatureInformation();
			vo.label = original.label;
			var originalParameters:Array = original.parameters;
			var parameters:Vector.<ParameterInformation> = new <ParameterInformation>[];
			var originalParametersCount:int = originalParameters.length;
			for(var i:int = 0; i < originalParametersCount; i++)
			{
				var resultParameter:Object = originalParameters;
				var parameter:ParameterInformation = new ParameterInformation();
				parameter.label = resultParameter[parameter];
				parameters[i] = parameter;
			}
			vo.parameters = parameters;
			return vo;
		}

		private function parseTextEdit(original:Object):TextEdit
		{
			var vo:TextEdit = new TextEdit();
			vo.range = this.parseRange(original.range);
			vo.newText = original.newText;
			return vo;
		}

		private function startNativeProcess():void
		{
			var processArgs:Vector.<String> = new <String>[];
			_shellInfo = new NativeProcessStartupInfo();
			var jarFile:File = File.applicationDirectory.resolvePath("elements/codecompletion.jar");
			processArgs.push("-Dmoonshine.port=" + _port);
			processArgs.push("-jar");
			processArgs.push(jarFile.nativePath);
			_shellInfo.arguments = processArgs;
			_shellInfo.executable = _cmdFile;
			initShell();
		}

		private function initShell():void
		{
			if (_nativeProcess)
			{
				_nativeProcess.exit();
			}
			else
			{
				startShell();
			}
		}

		private function startShell():void
		{
			_nativeProcess = new NativeProcess();
			_nativeProcess.addEventListener(ProgressEvent.STANDARD_OUTPUT_DATA, shellData);
			_nativeProcess.addEventListener(ProgressEvent.STANDARD_ERROR_DATA, shellError);
			_nativeProcess.addEventListener(NativeProcessExitEvent.EXIT, shellExit);
			_nativeProcess.start(_shellInfo);
		}

		private function parseData(data:String):void
		{
			if(!_connected)
			{
				connectToJava();
			}
		}

		protected function connectToJava():void
		{
			if(!_xmlSocket)
			{
				//Alert.show("XML Socket Start");
				_xmlSocket = new XMLSocket();
				_xmlSocket.addEventListener(Event.CONNECT, onSocketConnect);
				_xmlSocket.addEventListener(DataEvent.DATA, onIncomingData);
				_xmlSocket.addEventListener(IOErrorEvent.IO_ERROR,onSocketIOError);
				_xmlSocket.addEventListener(SecurityErrorEvent.SECURITY_ERROR,onSocketSecurityErr);
				_xmlSocket.addEventListener(Event.CLOSE,closeHandler);
				_connected = true;
				_xmlSocket.connect("127.0.0.1", _port);
			}
		}
		
		private function initializeLanguageServer():void
		{
			var sdkPath:String = getProjectSDKPath(_project, _model);
			if(!sdkPath)
			{
				//we'll need to try again later if the SDK changes
				return;
			}

			trace("Language server workspace root: " + project.folderPath);
			trace("Language Server framework SDK: " + sdkPath);

			_initialized = true;

			var obj:Object = new Object();
			obj.jsonrpc = "2.0";
			obj.id = getNextRequestID();
			obj.method = "initialize";
			var params:Object = new Object();
			params.frameworkSDK = sdkPath;
			params.workspacePath = _project.folderPath;
			obj.params = params;
			var jsonstr:String = JSON.stringify(obj);
			_xmlSocket.send(jsonstr);
			
			DidChangeConfigurationParams();
			var editors:ArrayCollection = _model.editors;
			var count:int = editors.length;
			for(var i:int = 0; i < count; i++)
			{
				var editor:IContentWindow = IContentWindow(editors.getItemAt(i));
				if(editor is ActionScriptTextEditor)
				{
					var asEditor:ActionScriptTextEditor = ActionScriptTextEditor(editor);
					if(isEditorInProject(asEditor))
					{
						var uri:String = asEditor.currentFile.fileBridge.url;
						sendDidOpenRequest(uri);
					}
				}
			}
		}

		private function sendDidOpenRequest(uri:String):void
		{
			var obj:Object = new Object();
			obj.jsonrpc = "2.0";
			obj.id = getNextRequestID();
			obj.method = "textDocument/didOpen";
			var textDocument:Object = new Object();
			textDocument.uri = uri;
			textDocument.languageId = "1";
			textDocument.version = 1;
			textDocument.text = "";
			var params:Object = new Object();
			params.textDocument = textDocument;
			obj.params = params;
			var jsonstr:String = JSON.stringify(obj);
			_xmlSocket.send(jsonstr);
		}

		private function DidChangeConfigurationParams():void
		{
			if(!_xmlSocket || !_initialized)
			{
				return;
			}
			var obj:Object = new Object();
			obj.jsonrpc = "2.0";
			obj.id = getNextRequestID();
			obj.method = "workspace/didChangeConfiguration";
			var buildOptions:BuildOptions = _project.buildOptions;
			var type:String = "app";
			var config:String = _project.air ? "air" : "flex";
			var compilerOptions:Object = {};
			compilerOptions["warnings"] = buildOptions.warnings;
			var sourcePathCount:int = _project.classpaths.length;
			if(sourcePathCount > 0)
			{
				var sourcePaths:Array = [];
				for(var i:int = 0; i < sourcePathCount; i++)
				{
					var sourcePath:String = _project.classpaths[i].fileBridge.nativePath;
					sourcePaths[i] = sourcePath;
				}
				compilerOptions["source-path"] = sourcePaths;
			}
			var libraryPathCount:int = _project.libraries.length;
			if(libraryPathCount > 0)
			{
				var libraryPaths:Array = [];
				for(i = 0; i < libraryPathCount; i++)
				{
					var libraryPath:String = _project.libraries[i].fileBridge.nativePath;
					libraryPaths[i] = libraryPath;
				}
				compilerOptions["library-path"] = libraryPaths;
			}
			var externalLibraryPathCount:int = _project.externalLibraries.length;
			if(externalLibraryPathCount > 0)
			{
				var externalLibraryPaths:Array = [];
				for(i = 0; i < externalLibraryPathCount; i++)
				{
					var externalLibraryPath:String = _project.externalLibraries[i].fileBridge.nativePath;
					externalLibraryPaths[i] = externalLibraryPath;
				}
				compilerOptions["external-library-path"] = externalLibraryPaths;
			}
			var files:Array = [];
			var filesCount:int = _project.targets.length;
			for(i = 0; i < filesCount; i++)
			{
				var file:String = _project.targets[i].fileBridge.nativePath;
				files[i] = file;
			}
			var additionalOptions:String = buildOptions.additional;
			//debug is handled separately and should not be duplicated
			additionalOptions = additionalOptions.replace(/--?debug=\w+/, "");

			//this object is designed to be similar to the asconfig.json
			//format used by vscode-nextgenas
			//https://github.com/BowlerHatLLC/vscode-nextgenas/wiki/asconfig.json
			//https://github.com/BowlerHatLLC/vscode-nextgenas/blob/master/distribution/src/assembly/schemas/asconfig.schema.json
			var DidChangeConfigurationParams:Object = {};
			DidChangeConfigurationParams.frameworkSDK = getProjectSDKPath(_project, _model);
			DidChangeConfigurationParams.type = type;
			DidChangeConfigurationParams.config = config;
			DidChangeConfigurationParams.files = files;
			DidChangeConfigurationParams.compilerOptions = compilerOptions;
			if(additionalOptions)
			{
				DidChangeConfigurationParams.additionalOptions = additionalOptions;
			}
			var params:Object = new Object();
			params.DidChangeConfigurationParams = DidChangeConfigurationParams;
			obj.params = params;
			var jsonstr:String = JSON.stringify(obj);
			_xmlSocket.send(jsonstr);
		}

		private function shellData(e:ProgressEvent):void
		{
			var output:IDataInput = _nativeProcess.standardOutput;
			parseData(output.readUTFBytes(output.bytesAvailable));
		}

		private function shellError(e:ProgressEvent):void
		{
			var output:IDataInput = _nativeProcess.standardError;
			var data:String = output.readUTFBytes(output.bytesAvailable);
			ConsoleUtil.print("shellError " + data + ".");
			ConsoleOutputter.formatOutput(HtmlFormatter.sprintfa(data, null), 'weak');
			var match:Array;
			//A new filter added here which will detect command for FDB exit
			match = data.match(/.*\ onConnected */);
			if(match)
			{
				trace(data);
				parseData(output.readUTFBytes(output.bytesAvailable));
			}
			else
			{
				trace(data);
				//Alert.show("jar connection "+data);
			}

		}

		private function shellExit(e:NativeProcessExitEvent):void
		{
			if(_xmlSocket)
			{
				shutdownHandler(null);
			}
			_nativeProcess.removeEventListener(ProgressEvent.STANDARD_OUTPUT_DATA, shellData);
			_nativeProcess.removeEventListener(ProgressEvent.STANDARD_ERROR_DATA, shellError);
			_nativeProcess.removeEventListener(NativeProcessExitEvent.EXIT, shellExit);
			_nativeProcess.exit();
			_nativeProcess = null;
		}

		private function closeHandler(evt:Event):void{
			if(_xmlSocket){
				_xmlSocket.close();
				_xmlSocket = null;
			}

		}

		private function onSocketConnect(event:Event):void
		{
			initializeLanguageServer();
		}

		private function onSocketIOError(event:IOErrorEvent):void {
			ConsoleUtil.print("ioError " + event.text + ".");
			ConsoleOutputter.formatOutput(HtmlFormatter.sprintfa("ioError "+event, null), 'weak');
		}

		private function onSocketSecurityErr(event:SecurityErrorEvent):void {
			ConsoleUtil.print("securityError " + event.text + ".");
			ConsoleOutputter.formatOutput(HtmlFormatter.sprintfa("securityError "+event, null), 'weak');
		}

		//Read Incoming data
		private function onIncomingData(event:DataEvent):void
		{
			var data:String = event.data;
			var object:Object = null;
			try
			{
				object = JSON.parse(data);
			}
			catch(error:Error)
			{
				trace("invalid JSON");
				return;
			}
			if("method" in object)
			{
				var method:String = object.method;
				if(method === "textDocument/publishDiagnostics")
				{
					var diagnosticsParams:Object = object.params;
					var uri:String = diagnosticsParams.uri;
					var path:String = (new File(uri)).nativePath;
					var resultDiagnostics:Array = diagnosticsParams.diagnostics;
					var diagnostics:Vector.<Diagnostic> = new <Diagnostic>[];
					var diagnosticsCount:int = resultDiagnostics.length;
					for(var i:int = 0; i < diagnosticsCount; i++)
					{
						var resultDiagnostic:Object = resultDiagnostics[i];
						diagnostics[i] = parseDiagnostic(path, resultDiagnostic);
					}
					GlobalEventDispatcher.getInstance().dispatchEvent(new DiagnosticsEvent(DiagnosticsEvent.EVENT_SHOW_DIAGNOSTICS, path, diagnostics));
				}
			}
			else if("result" in object && "id" in object)
			{
				var result:Object = object.result;
				var requestID:int = object.id as int;
				if("items" in result) //completion
				{
					var resultCompletionItems:Array = result.items as Array;
					if(resultCompletionItems)
					{
						var eventCompletionItems:Array = new Array();
						var completionItemCount:int = resultCompletionItems.length;
						for(i = 0; i < completionItemCount; i++)
						{
							var resultItem:Object = resultCompletionItems[i];
							eventCompletionItems[i] = parseCompletionItem(resultItem);
						}
						eventCompletionItems.sortOn("label",Array.CASEINSENSITIVE);
						_dispatcher.dispatchEvent(new CompletionItemsEvent(CompletionItemsEvent.EVENT_SHOW_COMPLETION_LIST,eventCompletionItems));
					}
				}
				if("signatures" in result) //signature help
				{
					var resultSignatures:Array = result.signatures as Array;
					if(resultSignatures && resultSignatures.length > 0)
					{
						var eventSignatures:Vector.<SignatureInformation> = new <SignatureInformation>[];
						var resultSignaturesCount:int = resultSignatures.length;
						for(i = 0; i < resultSignaturesCount; i++)
						{
							var resultSignature:Object = resultSignatures[i];
							eventSignatures[i] = parseSignatureInformation(resultSignature);
						}
						var signatureHelp:SignatureHelp = new SignatureHelp();
						signatureHelp.signatures = eventSignatures;
						signatureHelp.activeSignature = result.activeSignature;
						signatureHelp.activeParameter = result.activeParameter;
						_dispatcher.dispatchEvent(new SignatureHelpEvent(SignatureHelpEvent.EVENT_SHOW_SIGNATURE_HELP, signatureHelp));
					}
				}
				if("contents" in result) //hover
				{
					var resultContents:Array = result.contents as Array;
					if(resultContents)
					{
						var eventContents:Vector.<String> = new <String>[];
						var resultContentsCount:int = resultContents.length;
						for(i = 0; i < resultContentsCount; i++)
						{
							var resultContent:String = resultContents[i];
							//strip markdown formatting
							if(resultContent.indexOf(MARKDOWN_NEXTGENAS_START) === 0)
							{
								resultContent = resultContent.substr(MARKDOWN_NEXTGENAS_START.length);
							}
							if(resultContent.indexOf(MARKDOWN_MXML_START) === 0)
							{
								resultContent = resultContent.substr(MARKDOWN_MXML_START.length);
							}
							var expectedEndIndex:int = resultContent.length - MARKDOWN_CODE_END.length;
							if(resultContent.lastIndexOf(MARKDOWN_CODE_END) === expectedEndIndex)
							{
								resultContent = resultContent.substr(0, expectedEndIndex);
							}
							eventContents[i] = resultContent;
						}
						_dispatcher.dispatchEvent(new HoverEvent(HoverEvent.EVENT_SHOW_HOVER, eventContents));
					}
				}
				if("changes" in result) //rename
				{
					var resultChanges:Object = result.changes;
					var eventChanges:Object = {};
					for(var key:String in resultChanges)
					{
						var resultChangesList:Array = resultChanges[key] as Array;
						var eventChangesList:Vector.<TextEdit> = new <TextEdit>[];
						var resultChangesCount:int = resultChangesList.length;
						for(i = 0; i < resultChangesCount; i++)
						{
							var resultChange:Object = resultChangesList[i];
							eventChangesList[i] = this.parseTextEdit(resultChange);
						}
						eventChanges[key] = eventChangesList;
					}
					_dispatcher.dispatchEvent(new RenameEvent(RenameEvent.EVENT_APPLY_RENAME, eventChanges));
				}
				if(result is Array) //definitions
				{
					if(requestID in _gotoDefinitionLookup)
					{
						var position:Position = _gotoDefinitionLookup[requestID] as Position;
						delete _gotoDefinitionLookup[requestID];
						var resultLocations:Array = result as Array;
						var eventLocations:Vector.<Location> = new <Location>[];
						var resultLocationsCount:int = resultLocations.length;
						for(i = 0; i < resultLocationsCount; i++)
						{
							var resultLocation:Object = resultLocations[i];
							eventLocations[i] = parseLocation(resultLocation);
						}
						_dispatcher.dispatchEvent(new GotoDefinitionEvent(GotoDefinitionEvent.EVENT_SHOW_DEFINITION_LINK, eventLocations, position));
					}
					else if(requestID in _findReferencesLookup)
					{
						delete _findReferencesLookup[requestID];
						var resultReferences:Array = result as Array;
						var eventReferences:Vector.<Location> = new <Location>[];
						var resultReferencesCount:int = resultReferences.length;
						for(i = 0; i < resultReferencesCount; i++)
						{
							var resultReference:Object = resultReferences[i];
							eventReferences[i] = parseLocation(resultReference);
						}
						_dispatcher.dispatchEvent(new ReferencesEvent(ReferencesEvent.EVENT_SHOW_REFERENCES, eventReferences));
					}
					else //document or workspace symbols
					{
						var resultSymbolInfos:Array = result as Array;
						var eventSymbolInfos:Vector.<SymbolInformation> = new <SymbolInformation>[];
						var resultSymbolInfosCount:int = resultSymbolInfos.length;
						for(i = 0; i < resultSymbolInfosCount; i++)
						{
							var resultSymbolInfo:Object = resultSymbolInfos[i];
							eventSymbolInfos[i] = parseSymbolInformation(resultSymbolInfo);
						}
						_dispatcher.dispatchEvent(new SymbolsEvent(SymbolsEvent.EVENT_SHOW_SYMBOLS, eventSymbolInfos));
					}
				}
			}
		}

		//For shutdown java socket
		public function shutdownHandler(event:Event):void{
			if(_xmlSocket)
			{
				_xmlSocket.send("SHUTDOWN");
				_xmlSocket = null;
			}
		}

		private function removeProjectHandler(event:ProjectEvent):void
		{
			if(event.project !== _project)
			{
				return;
			}
			_project.removeEventListener(AS3ProjectVO.CHANGE_CUSTOM_SDK, projectChangeCustomSDKHandler);
			_dispatcher.removeEventListener(ProjectEvent.REMOVE_PROJECT, removeProjectHandler);
			_dispatcher.removeEventListener(TypeAheadEvent.EVENT_DIDOPEN, didOpenCall);
			_dispatcher.removeEventListener(TypeAheadEvent.EVENT_DIDCHANGE, didChangeCall);
			_dispatcher.removeEventListener(TypeAheadEvent.EVENT_TYPEAHEAD, completionHandler);
			_dispatcher.removeEventListener(TypeAheadEvent.EVENT_SIGNATURE_HELP, signatureHelpHandler);
			_dispatcher.removeEventListener(TypeAheadEvent.EVENT_HOVER, hoverHandler);
			_dispatcher.removeEventListener(TypeAheadEvent.EVENT_GOTO_DEFINITION, gotoDefinitionHandler);
			_dispatcher.removeEventListener(TypeAheadEvent.EVENT_WORKSPACE_SYMBOLS, workspaceSymbolsHandler);
			_dispatcher.removeEventListener(TypeAheadEvent.EVENT_DOCUMENT_SYMBOLS, documentSymbolsHandler);
			_dispatcher.removeEventListener(TypeAheadEvent.EVENT_FIND_REFERENCES, findReferencesHandler);
			_dispatcher.removeEventListener(MenuPlugin.CHANGE_MENU_SDK_STATE, changeMenuSDKStateHandler);
			_dispatcher.removeEventListener(MenuPlugin.MENU_QUIT_EVENT, shutdownHandler);
		}

		private function projectChangeCustomSDKHandler(event:Event):void
		{
			if(_initialized)
			{
				//we've already initialized the server
				trace("Change custom SDK Path:", _project.customSDKPath);
				trace("Language Server framework SDK: " + getProjectSDKPath(_project, _model));
				DidChangeConfigurationParams();
			}
			else
			{
				//we haven't initialized the server yet
				initializeLanguageServer();
			}
		}

		private function changeMenuSDKStateHandler(event:Event):void
		{
			if(_initialized)
			{
				//we've already initialized the server
				var defaultSDKPath:String = "None";
				var defaultSDK:FileLocation = _model.defaultSDK;
				if(defaultSDK)
				{
					defaultSDKPath = _model.defaultSDK.fileBridge.nativePath;
				}
				trace("change global SDK:", defaultSDKPath);
				trace("Language Server framework SDK: " + getProjectSDKPath(_project, _model));
				DidChangeConfigurationParams();
			}
			else
			{
				//we haven't initialized the server yet
				initializeLanguageServer();
			}
		}

		//Call Didopen from Java
		private function didOpenCall(event:TypeAheadEvent):void{
			if(!_xmlSocket || !_initialized)
			{
				return;
			}
			if(event.isDefaultPrevented() || !isActiveEditorInProject())
			{
				return;
			}
			event.preventDefault();

			DidChangeConfigurationParams();
			sendDidOpenRequest(event.uri);
		}

		private function didChangeCall(event:TypeAheadEvent):void{
			if(!_xmlSocket || !_initialized)
			{
				return;
			}
			if(event.isDefaultPrevented() || !isActiveEditorInProject())
			{
				return;
			}
			event.preventDefault();

			var obj:Object = new Object();
			obj.jsonrpc = "2.0";
			obj.id = getNextRequestID();
			obj.method = "textDocument/didChange";

			var textDocument:Object = new Object();
			textDocument.version = 1;
			textDocument.uri = (_model.activeEditor as BasicTextEditor).currentFile.fileBridge.url;

			var range:Object = new Object();
			var startposition:Object = new Object();
			startposition.line = event.startLineNumber;
			startposition.character = event.startLinePos;
			range.start = startposition;

			var endposition:Object = new Object();
			endposition.line = event.endLineNumber;
			endposition.character = event.endLinePos;
			range.end = endposition;

			var contentChangesArr:Array = new Array();
			var contentChanges:Object = new Object();
			contentChanges.range = null;//range;
			contentChanges.rangeLength = 0;//evt.textlen;
			contentChanges.text = event.newText;

			var DidChangeTextDocumentParams:Object = new Object();
			DidChangeTextDocumentParams.textDocument = textDocument;
			DidChangeTextDocumentParams.contentChanges = contentChanges;

			var params:Object = new Object();
			params.DidChangeTextDocumentParams = DidChangeTextDocumentParams;
			obj.params = params;
			var jsonstr:String = JSON.stringify(obj);
			_xmlSocket.send(jsonstr);
		}

		private function completionHandler(event:TypeAheadEvent):void{
			if(!_xmlSocket || !_initialized)
			{
				return;
			}
			if(event.isDefaultPrevented() || !isActiveEditorInProject())
			{
				return;
			}
			event.preventDefault();

			var obj:Object = new Object();
			obj.jsonrpc = "2.0";
			obj.id = getNextRequestID();
			obj.method = "textDocument/completion";

			var textDocument:Object = new Object();
			textDocument.uri = (_model.activeEditor as BasicTextEditor).currentFile.fileBridge.url;

			var position:Object = new Object();
			position.line = event.endLineNumber;
			position.character = event.endLinePos;

			var TextDocumentPositionParams:Object = new Object();
			TextDocumentPositionParams.textDocument = textDocument;
			TextDocumentPositionParams.position = position;

			var params:Object = new Object();
			params.TextDocumentPositionParams = TextDocumentPositionParams;
			obj.params = params;

			var jsonstr:String = JSON.stringify(obj);
			_xmlSocket.send(jsonstr);
		}

		private function signatureHelpHandler(event:TypeAheadEvent):void
		{
			if(!_xmlSocket || !_initialized)
			{
				return;
			}
			if(event.isDefaultPrevented() || !isActiveEditorInProject())
			{
				return;
			}
			event.preventDefault();

			var obj:Object = new Object();
			obj.jsonrpc = "2.0";
			obj.id = getNextRequestID();
			obj.method = "textDocument/signatureHelp";

			var textDocument:Object = new Object();
			textDocument.uri = (_model.activeEditor as BasicTextEditor).currentFile.fileBridge.url;

			var position:Object = new Object();
			position.line = event.endLineNumber;
			position.character = event.endLinePos;

			var TextDocumentPositionParams:Object = new Object();
			TextDocumentPositionParams.textDocument = textDocument;
			TextDocumentPositionParams.position = position;

			var params:Object = new Object();
			params.TextDocumentPositionParams = TextDocumentPositionParams;
			obj.params = params;

			var jsonstr:String = JSON.stringify(obj);
			_xmlSocket.send(jsonstr);
		}

		private function hoverHandler(event:TypeAheadEvent):void
		{
			if(!_xmlSocket || !_initialized)
			{
				return;
			}
			if(event.isDefaultPrevented() || !isActiveEditorInProject())
			{
				return;
			}
			event.preventDefault();

			var obj:Object = new Object();
			obj.jsonrpc = "2.0";
			obj.id = getNextRequestID();
			obj.method = "textDocument/hover";

			var textDocument:Object = new Object();
			textDocument.uri = (_model.activeEditor as BasicTextEditor).currentFile.fileBridge.url;

			var position:Object = new Object();
			position.line = event.endLineNumber;
			position.character = event.endLinePos;

			var TextDocumentPositionParams:Object = new Object();
			TextDocumentPositionParams.textDocument = textDocument;
			TextDocumentPositionParams.position = position;

			var params:Object = new Object();
			params.TextDocumentPositionParams = TextDocumentPositionParams;
			obj.params = params;

			var jsonstr:String = JSON.stringify(obj);
			_xmlSocket.send(jsonstr);
		}

		private function gotoDefinitionHandler(event:TypeAheadEvent):void
		{
			if(!_xmlSocket || !_initialized)
			{
				return;
			}
			if(event.isDefaultPrevented() || !isActiveEditorInProject())
			{
				return;
			}
			event.preventDefault();

			var obj:Object = new Object();
			obj.jsonrpc = "2.0";
			obj.id = getNextRequestID();
			obj.method = "textDocument/definition";
			_gotoDefinitionLookup[obj.id] = new Position(event.endLineNumber, event.endLinePos);

			var textDocument:Object = new Object();
			textDocument.uri = (_model.activeEditor as BasicTextEditor).currentFile.fileBridge.url;

			var position:Object = new Object();
			position.line = event.endLineNumber;
			position.character = event.endLinePos;

			var TextDocumentPositionParams:Object = new Object();
			TextDocumentPositionParams.textDocument = textDocument;
			TextDocumentPositionParams.position = position;

			var params:Object = new Object();
			params.TextDocumentPositionParams = TextDocumentPositionParams;
			obj.params = params;

			var jsonstr:String = JSON.stringify(obj);
			_xmlSocket.send(jsonstr);
		}

		private function workspaceSymbolsHandler(event:TypeAheadEvent):void
		{
			if(!_xmlSocket || !_initialized)
			{
				return;
			}
			if(event.isDefaultPrevented() || !isActiveEditorInProject())
			{
				return;
			}
			event.preventDefault();

			var query:String = event.newText;

			var obj:Object = new Object();
			obj.jsonrpc = "2.0";
			obj.id = getNextRequestID();
			obj.method = "workspace/symbol";

			var WorkspaceSymbolParams:Object = new Object();
			WorkspaceSymbolParams.query = query;

			var params:Object = new Object();
			params.WorkspaceSymbolParams = WorkspaceSymbolParams;
			obj.params = params;

			var jsonstr:String = JSON.stringify(obj);
			_xmlSocket.send(jsonstr);
		}

		private function documentSymbolsHandler(event:TypeAheadEvent):void
		{
			if(!_xmlSocket || !_initialized)
			{
				return;
			}
			if(event.isDefaultPrevented() || !isActiveEditorInProject())
			{
				return;
			}
			event.preventDefault();

			var obj:Object = new Object();
			obj.jsonrpc = "2.0";
			obj.id = getNextRequestID();
			obj.method = "textDocument/documentSymbol";

			var textDocument:Object = new Object();
			textDocument.uri = (_model.activeEditor as BasicTextEditor).currentFile.fileBridge.url;

			var DocumentSymbolParams:Object = new Object();
			DocumentSymbolParams.textDocument = textDocument;

			var params:Object = new Object();
			params.DocumentSymbolParams = DocumentSymbolParams;
			obj.params = params;

			var jsonstr:String = JSON.stringify(obj);
			_xmlSocket.send(jsonstr);
		}

		private function findReferencesHandler(event:TypeAheadEvent):void
		{
			if(!_xmlSocket || !_initialized)
			{
				return;
			}
			if(event.isDefaultPrevented() || !isActiveEditorInProject())
			{
				return;
			}
			event.preventDefault();

			var obj:Object = new Object();
			obj.jsonrpc = "2.0";
			obj.id = getNextRequestID();
			obj.method = "textDocument/references";
			_findReferencesLookup[obj.id] = true;

			var textDocument:Object = new Object();
			textDocument.uri = (_model.activeEditor as BasicTextEditor).currentFile.fileBridge.url;

			var position:Object = new Object();
			position.line = event.endLineNumber;
			position.character = event.endLinePos;

			var context:Object = new Object();
			context.includeDeclaration = true;

			var ReferenceParams:Object = new Object();
			ReferenceParams.textDocument = textDocument;
			ReferenceParams.position = position;
			ReferenceParams.context = context;

			var params:Object = new Object();
			params.ReferenceParams = ReferenceParams;
			obj.params = params;

			var jsonstr:String = JSON.stringify(obj);
			_xmlSocket.send(jsonstr);
		}

		private function renameHandler(event:TypeAheadEvent):void
		{
			if(!_xmlSocket || !_initialized)
			{
				return;
			}
			if(event.isDefaultPrevented() || !isActiveEditorInProject())
			{
				return;
			}
			event.preventDefault();

			var obj:Object = new Object();
			obj.jsonrpc = "2.0";
			obj.id = getNextRequestID();
			obj.method = "textDocument/rename";
			_findReferencesLookup[obj.id] = true;

			var textDocument:Object = new Object();
			textDocument.uri = (_model.activeEditor as BasicTextEditor).currentFile.fileBridge.url;

			var position:Object = new Object();
			position.line = event.endLineNumber;
			position.character = event.endLinePos;

			var RenameParams:Object = new Object();
			RenameParams.textDocument = textDocument;
			RenameParams.position = position;
			RenameParams.newName = event.newText;

			var params:Object = new Object();
			params.RenameParams = RenameParams;
			obj.params = params;

			var jsonstr:String = JSON.stringify(obj);
			_xmlSocket.send(jsonstr);
		}
	}
}
