////////////////////////////////////////////////////////////////////////////////
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
// No warranty of merchantability or fitness of any kind. 
// Use this software at your own risk.
// 
////////////////////////////////////////////////////////////////////////////////
package actionScripts.plugins.as3project.mxmlc
{
	import flash.desktop.NativeProcess;
	import flash.desktop.NativeProcessStartupInfo;
	import flash.display.DisplayObject;
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.events.NativeProcessExitEvent;
	import flash.events.ProgressEvent;
	import flash.filesystem.File;
	import flash.utils.Dictionary;
	import flash.utils.IDataInput;
	import flash.utils.IDataOutput;
	
	import mx.collections.ArrayCollection;
	import mx.controls.Alert;
	import mx.core.FlexGlobals;
	import mx.managers.PopUpManager;
	import mx.resources.ResourceManager;
	
	import actionScripts.events.GlobalEventDispatcher;
	import actionScripts.events.ProjectEvent;
	import actionScripts.events.RefreshTreeEvent;
	import actionScripts.events.StatusBarEvent;
	import actionScripts.factory.FileLocation;
	import actionScripts.locator.IDEModel;
	import actionScripts.plugin.IPlugin;
	import actionScripts.plugin.PluginBase;
	import actionScripts.plugin.actionscript.as3project.vo.AS3ProjectVO;
	import actionScripts.plugin.actionscript.as3project.vo.SWFOutputVO;
	import actionScripts.plugin.actionscript.mxmlc.CommandLine;
	import actionScripts.plugin.actionscript.mxmlc.MXMLCPluginEvent;
	import actionScripts.plugin.console.MarkupTextLineModel;
	import actionScripts.plugin.core.compiler.CompilerEventBase;
	import actionScripts.plugin.settings.ISettingsProvider;
	import actionScripts.plugin.settings.event.SetSettingsEvent;
	import actionScripts.plugin.settings.vo.BooleanSetting;
	import actionScripts.plugin.settings.vo.ISetting;
	import actionScripts.plugin.settings.vo.PathSetting;
	import actionScripts.plugins.swflauncher.SWFLauncherPlugin;
	import actionScripts.plugins.swflauncher.event.SWFLaunchEvent;
	import actionScripts.ui.editor.text.TextLineModel;
	import actionScripts.ui.menu.MenuPlugin;
	import actionScripts.utils.HtmlFormatter;
	import actionScripts.utils.NoSDKNotifier;
	import actionScripts.utils.OSXBookmarkerNotifiers;
	import actionScripts.utils.SDKUtils;
	import actionScripts.utils.UtilsCore;
	import actionScripts.valueObjects.ConstantsCoreVO;
	import actionScripts.valueObjects.ProjectReferenceVO;
	import actionScripts.valueObjects.ProjectVO;
	import actionScripts.valueObjects.Settings;
	
	import components.popup.SelectOpenedFlexProject;
	import components.popup.UnsaveFileMessagePopup;
	import components.views.project.TreeView;
	
	import org.as3commons.asblocks.utils.FileUtil;
	
	public class MXMLCPlugin extends PluginBase implements IPlugin, ISettingsProvider
	{
		override public function get name():String			{ return "MXMLC Compiler Plugin"; }
		override public function get author():String		{ return "Miha Lunar & Moonshine Project Team"; }
		override public function get description():String	{ return ResourceManager.getInstance().getString('resources','plugin.desc.mxmlc'); }
		
		public var incrementalCompile:Boolean = true;
		protected var runAfterBuild:Boolean;
		protected var debugAfterBuild:Boolean;
		protected var release:Boolean;
		private var fcshPath:String = "bin/fcsh";
		private var mxmlcPath:String = "bin/mxmlc"
		private var cmdFile:File;
		private var _defaultFlexSDK:String
		private var fcsh:NativeProcess;
		private var exiting:Boolean = false;
		private var shellInfo:NativeProcessStartupInfo;
		
		private var lastTarget:File;
		private var targets:Dictionary;
		
		private var currentSDK:File = flexSDK;
		
		/** Project currently under compilation */
		private var currentProject:ProjectVO;
		private var queue:Vector.<String> = new Vector.<String>();
		private var errors:String = "";
		
		private var cmdLine:CommandLine;
		private var _instance:MXMLCPlugin;
		private var	tempObj:Object;
		private var fschstr:String;
		private var SDKstr:String;
		private var selectProjectPopup:SelectOpenedFlexProject;
		private var pop:UnsaveFileMessagePopup;
		
		public function get flexSDK():File
		{
			return currentSDK;
		}
		
		public function get defaultFlexSDK():String
		{
			return _defaultFlexSDK;
		}
		
		public function set defaultFlexSDK(value:String):void
		{
			_defaultFlexSDK = value;
			if (_defaultFlexSDK == "")
			{
				// check if any bundled SDK present or not
				// if present, make one default
				if (model.userSavedSDKs.length > 0 && model.userSavedSDKs[0].status == SDKUtils.BUNDLED)
				{
					_defaultFlexSDK = model.userSavedSDKs[0].path;
					SDKUtils.setDefaultSDKByBundledSDK();
				}
				else
				{
					model.defaultSDK = null;
				}
			}
			else
			{
				for each (var i:ProjectReferenceVO in IDEModel.getInstance().userSavedSDKs)
				{
					if (i.path == value)
					{
						model.defaultSDK = new FileLocation(i.path);
						model.noSDKNotifier.dispatchEvent(new Event(NoSDKNotifier.SDK_SAVED));
						break
					}
				}
				
				// even if above condition do not made 
				// check one more condition - this is particularly valid 
				// if we have bundled SDKs and an old bundled SDK 
				// references not found in newer bundled SDKs
				if (!model.defaultSDK)
				{
					for each (i in IDEModel.getInstance().userSavedSDKs)
					{
						if (i.path == value)
						{
							model.defaultSDK = new FileLocation(i.path);
							model.noSDKNotifier.dispatchEvent(new Event(NoSDKNotifier.SDK_SAVED));
							break
						}
					}
				}
				
				// update project-to-sdk references once again
				for each (var j:AS3ProjectVO in model.projects)
				{
					dispatcher.dispatchEvent(
						new ProjectEvent(ProjectEvent.ADD_PROJECT, j)
					);
				}
			}
			
			// state change of menus based upon default SDK presence
			dispatcher.dispatchEvent(new Event(MenuPlugin.CHANGE_MENU_SDK_STATE));
		}
		
		public function MXMLCPlugin() 
		{
			if (Settings.os == "win")
			{
				fcshPath += ".bat";
				mxmlcPath +=".bat";
				cmdFile = new File("c:\\Windows\\System32\\cmd.exe");
			}
			else
			{
				cmdFile = new File("/bin/bash");
			}
			
			// @devsena
			// for some unknown reason activate() for this plugin
			// fail to run when 'revoke all access' in PKG run.
			// for now, I'm directing the access from here rather than
			// automated process, I shall need to check this later.
			activate();
			
			SDKUtils.initBundledSDKs();
		}
		
		override public function activate():void 
		{
			if (activated) return;
			
			super.activate();
			
			dispatcher.addEventListener(CompilerEventBase.BUILD_AND_RUN, buildAndRun);
			dispatcher.addEventListener(CompilerEventBase.BUILD_AND_DEBUG, buildAndRun);
			dispatcher.addEventListener(CompilerEventBase.BUILD, build);
			dispatcher.addEventListener(CompilerEventBase.BUILD_RELEASE, buildRelease);
			dispatcher.addEventListener(ProjectEvent.FLEX_SDK_UDPATED_OUTSIDE, onDefaultSDKUpdatedOutside);
			
			tempObj = new Object();
			tempObj.callback = buildCommand;
			tempObj.commandDesc = "Build the currently selected Flex project.";
			registerCommand('build',tempObj);
			
			tempObj = new Object();
			tempObj.callback = runCommand;
			tempObj.commandDesc = "Build and run the currently selected Flex project.";
			registerCommand('run',tempObj);
			
			tempObj = new Object();
			tempObj.callback = releaseCommand;
			tempObj.commandDesc = "Build the currently selected project in release mode.";
			tempObj.style = "red";
			registerCommand('release',tempObj);
			
			cmdLine = new CommandLine();
			reset();
		}
		
		override public function deactivate():void 
		{
			super.deactivate(); 
			
			reset();
			shellInfo = null;
			cmdLine = null;
		}
		
		public function getSettingsList():Vector.<ISetting>
		{
			return Vector.<ISetting>([
				new PathSetting(this,'defaultFlexSDK', 'Default Apache Flex® or FlexJS® SDK', true, defaultFlexSDK, true),
				new BooleanSetting(this,'incrementalCompile', 'Incremental Compilation')
			]);
		}
		
		private function buildCommand(args:Array):void
		{
			build(null, false);
		}
		
		private function runCommand(args:Array):void
		{
			build(null, true);
		}
		
		private function releaseCommand(args:Array):void
		{
			build(null, false, true);
		}
		
		private function reset():void 
		{
			startShell(false);
			//exiting = true;
			
			targets = new Dictionary();
			errors = "";
		}
		
		private function onDefaultSDKUpdatedOutside(event:ProjectEvent):void
		{
			// @note
			// basically requires to listen to update in
			// Flex SDKs window
			var tmpRef:ProjectReferenceVO = event.anObject as ProjectReferenceVO;
			if (!tmpRef) return;
			defaultFlexSDK = tmpRef.path;
			
			var thisSettings: Vector.<ISetting> = getSettingsList();
			var pathSettingToDefaultSDK:PathSetting = thisSettings[0] as PathSetting;
			pathSettingToDefaultSDK.stringValue = defaultFlexSDK;
			dispatcher.dispatchEvent(new SetSettingsEvent(SetSettingsEvent.SAVE_SPECIFIC_PLUGIN_SETTING, null, "actionScripts.plugins.as3project.mxmlc::MXMLCPlugin", thisSettings));
		}
		
		private function buildAndRun(e:Event):void
		{
			SWFLauncherPlugin.RUN_AS_DEBUGGER = (e.type == CompilerEventBase.BUILD_AND_DEBUG) ? true : false;
			build(e, true);	
		}
		
		private function buildRelease(e:Event):void
		{
			SWFLauncherPlugin.RUN_AS_DEBUGGER = false;
			build(e, false, true);
		}
		
		private function sdkSelected(event:Event):void
		{
			sdkSelectionCancelled(null);
			// update swf version if a newer SDK now saved than previously saved one
			AS3ProjectVO(currentProject).swfOutput.swfVersion = SWFOutputVO.getSDKSWFVersion();
			// continue with waiting build process again
			proceedWithBuild(currentProject);
		}
		
		private function sdkSelectionCancelled(event:Event):void
		{
			model.noSDKNotifier.removeEventListener(NoSDKNotifier.SDK_SAVED, sdkSelected);
			model.noSDKNotifier.removeEventListener(NoSDKNotifier.SDK_SAVE_CANCELLED, sdkSelectionCancelled);
		}
		
		private function build(e:Event, runAfterBuild:Boolean=false, release:Boolean=false):void 
		{
			if(e && e.type=="compilerBuildAndDebug")
			{
				this.debugAfterBuild = true;
				SWFLauncherPlugin.RUN_AS_DEBUGGER = true;
			}
			else
			{
				this.debugAfterBuild = false;
				SWFLauncherPlugin.RUN_AS_DEBUGGER = false;
			}
			
			this.runAfterBuild = runAfterBuild;
			this.release = release;
			buildStart();
		}
		
		private function buildStart():void
		{
			// check if there is multiple projects were opened in tree view
			if (model.projects.length > 1)
			{
				// check if user has selection/select any particular project or not
				if (model.mainView.isProjectViewAdded)
				{
					var tmpTreeView:TreeView = model.mainView.getTreeViewPanel();
					var projectReference:AS3ProjectVO = tmpTreeView.getProjectBySelection();
					if (projectReference)
					{
						checkForUnsavedEdior(projectReference as ProjectVO);
						return;
					}
				}
				// if above is false
				selectProjectPopup = new SelectOpenedFlexProject();
				PopUpManager.addPopUp(selectProjectPopup, FlexGlobals.topLevelApplication as DisplayObject, false);
				PopUpManager.centerPopUp(selectProjectPopup);
				selectProjectPopup.addEventListener(SelectOpenedFlexProject.PROJECT_SELECTED, onProjectSelected);
				selectProjectPopup.addEventListener(SelectOpenedFlexProject.PROJECT_SELECTION_CANCELLED, onProjectSelectionCancelled);
			}
			else if (model.projects.length != 0)
			{
				checkForUnsavedEdior(model.projects[0] as ProjectVO);
			}
			
			/*
			* @local
			*/
			function onProjectSelected(event:Event):void
			{
				checkForUnsavedEdior(selectProjectPopup.selectedProject);
				onProjectSelectionCancelled(null);
			}
			
			function onProjectSelectionCancelled(event:Event):void
			{
				selectProjectPopup.removeEventListener(SelectOpenedFlexProject.PROJECT_SELECTED, onProjectSelected);
				selectProjectPopup.removeEventListener(SelectOpenedFlexProject.PROJECT_SELECTION_CANCELLED, onProjectSelectionCancelled);
				selectProjectPopup = null;
			}
			
			/*
			* check for unsaved File
			*/
			function checkForUnsavedEdior(activeProject:ProjectVO):void
			{
				UtilsCore.checkForUnsavedEdior(activeProject, proceedWithBuild);
				//proceedWithBuild(activeProject);
			}
		}
		
		private function proceedWithBuild(activeProject:ProjectVO):void
		{
			reset();
			
			// Don't compile if there is no project. Don't warn since other compilers might take the job.
			if (!activeProject) return;
			if (!(activeProject is AS3ProjectVO)) return;
			
			var as3Pvo:AS3ProjectVO = activeProject as AS3ProjectVO;
			if(as3Pvo.targets.length==0)
			{
				error("No targets found for compilation.");
				return;
			}
			
			CONFIG::OSX
			{
				// before proceed, check file access dependencies
				if (!OSXBookmarkerNotifiers.checkAccessDependencies(new ArrayCollection([as3Pvo]), "Access Manager - Build Halt!")) 
				{
					Alert.show("Please fix the dependencies before build.", "Error!");
					return;
				}
			}
			
			// Read file content to indentify the project type regular flex application or flexjs applicatino
			if (as3Pvo.FlexJS)
			{
				// FlexJS Application
				compileFlexJSApplication(activeProject, release);
			}
			else
			{
				//Regular application
				compileRegularFlexApplication(activeProject, release);
			}
		}
		
		/**
		 * @return True if the current SDK matches the project SDK, false otherwise
		 */
		private function usingInvalidSDK(pvo:AS3ProjectVO):Boolean 
		{
			var customSDK:File = pvo.buildOptions.customSDK.fileBridge.getFile as File;
			if ((customSDK && (currentSDK.nativePath != customSDK.nativePath))
				|| (!customSDK && currentSDK.nativePath != flexSDK.nativePath)) 
			{
				return true;
			}
			return false;
		}
		
		private function compileFlexJSApplication(pvo:ProjectVO, release:Boolean=false):void
		{
			if (!fcsh || pvo.folderLocation.fileBridge.nativePath != shellInfo.workingDirectory.nativePath 
				|| usingInvalidSDK(pvo as AS3ProjectVO)) 
			{
				currentProject = pvo;
				currentSDK = getCurrentSDK(pvo as AS3ProjectVO);
				if (!currentSDK)
				{
					model.noSDKNotifier.notifyNoFlexSDK(false);
					model.noSDKNotifier.addEventListener(NoSDKNotifier.SDK_SAVED, sdkSelected);
					model.noSDKNotifier.addEventListener(NoSDKNotifier.SDK_SAVE_CANCELLED, sdkSelectionCancelled);
					error("No Flex SDK found. Setup one in Settings menu.");
					return;
				}
				var mxmlcFile:File = currentSDK.resolvePath(mxmlcPath);
				if (!mxmlcFile.exists)
				{
					Alert.show("Invalid SDK - Please configure a FlexJS SDK instead","Error!");
					error("Invalid SDK - Please configure a FlexJS SDK instead");
					return;
				}
				//If application is flexJS and sdk is flex sdk then error popup alert
				var fcshFile:File = currentSDK.resolvePath(fcshPath);
				if (fcshFile.exists)
				{
					Alert.show("Invalid SDK - Please configure a FlexJS SDK instead","Error!");
					error("Invalid SDK - Please configure a FlexJS SDK instead");
					return;
				}
				fschstr = mxmlcFile.nativePath;
				fschstr = UtilsCore.convertString(fschstr);
				
				SDKstr = currentSDK.nativePath;
				SDKstr = UtilsCore.convertString(SDKstr);
				
				// update build config file
				AS3ProjectVO(pvo).updateConfig();
				
				var processArgs:Vector.<String> = new Vector.<String>;
				shellInfo = new NativeProcessStartupInfo();
				
				var FlexJSCompileStr:String = compile(pvo as AS3ProjectVO, release);
				FlexJSCompileStr = FlexJSCompileStr.substring(FlexJSCompileStr.indexOf(" -load-config"),FlexJSCompileStr.length);
				if(Settings.os == "win")
				{
					processArgs.push("/c");
					processArgs.push("set FLEX_HOME="+SDKstr+"&& "+fschstr + FlexJSCompileStr);
				}
				else
				{
					processArgs.push("-c");
					processArgs.push("export FLEX_HOME="+SDKstr+"&&"+"export FALCON_HOME="+SDKstr+"&&"+fschstr + FlexJSCompileStr);
				}
				//var workingDirectory:File = currentSDK.resolvePath("bin/");
				
				shellInfo.arguments = processArgs;
				shellInfo.executable = cmdFile;
				shellInfo.workingDirectory = pvo.folderLocation.fileBridge.getFile as File;
				
				initShell();
			}
		}
		
		private function compileRegularFlexApplication(pvo:ProjectVO, release:Boolean=false):void
		{
			if (!fcsh || pvo.folderLocation.fileBridge.nativePath != shellInfo.workingDirectory.nativePath 
				|| usingInvalidSDK(pvo as AS3ProjectVO)) 
			{
				currentProject = pvo;
				currentSDK = getCurrentSDK(pvo as AS3ProjectVO);
				if (!currentSDK)
				{
					model.noSDKNotifier.notifyNoFlexSDK(false);
					model.noSDKNotifier.addEventListener(NoSDKNotifier.SDK_SAVED, sdkSelected);
					model.noSDKNotifier.addEventListener(NoSDKNotifier.SDK_SAVE_CANCELLED, sdkSelectionCancelled);
					error("No Flex SDK found. Setup one in Settings menu.");
					return;
				}
				var fschFile:File = currentSDK.resolvePath(fcshPath);
				if (!fschFile.exists)
				{
					Alert.show("Invalid SDK - Please configure a Flex SDK instead.","Error!");
					error("Invalid SDK - Please configure a Flex SDK instead.");
					return;
				}
				fschstr = fschFile.nativePath;
				fschstr = UtilsCore.convertString(fschstr);
				
				SDKstr = currentSDK.nativePath;
				SDKstr = UtilsCore.convertString(SDKstr);
				
				// update build config file
				AS3ProjectVO(pvo).updateConfig();
				
				var processArgs:Vector.<String> = new Vector.<String>;
				shellInfo = new NativeProcessStartupInfo();
				if(Settings.os == "win")
				{
					processArgs.push("/c");
					processArgs.push("set FLEX_HOME="+SDKstr+"&& "+fschstr);
				}
				else
				{
					processArgs.push("-c");
					processArgs.push("export FLEX_HOME="+SDKstr+";"+fschstr);
				}
				//var workingDirectory:File = currentSDK.resolvePath("bin/");
				shellInfo.arguments = processArgs;
				shellInfo.executable = cmdFile;
				shellInfo.workingDirectory = pvo.folderLocation.fileBridge.getFile as File;
				
				initShell();
			}
			
			debug("SDK path: %s", currentSDK.nativePath);
			var compileStr:String = compile(pvo as AS3ProjectVO, release);
			send(compileStr);
		}
		
		private function getCurrentSDK(pvo:AS3ProjectVO):File 
		{
			return pvo.buildOptions.customSDK ? pvo.buildOptions.customSDK.fileBridge.getFile as File : (IDEModel.getInstance().defaultSDK ? IDEModel.getInstance().defaultSDK.fileBridge.getFile as File : null);
		}
		
		private function clearConsoleBeforeRun():void
		{
			if (ConstantsCoreVO.IS_CONSOLE_CLEARED_ONCE) clearOutput();
			ConstantsCoreVO.IS_CONSOLE_CLEARED_ONCE = true;
		}
		
		private function compile(pvo:AS3ProjectVO, release:Boolean=false):String 
		{
			clearConsoleBeforeRun();
			dispatcher.dispatchEvent(new MXMLCPluginEvent(CompilerEventBase.PREBUILD, new FileLocation(currentSDK.nativePath)));
			print("Compiling "+pvo.projectName);
			
			currentProject = pvo;
			if (pvo.targets.length == 0) 
			{
				error("No targets found for compilation.");
				return "";
			}
			var file:FileLocation = pvo.targets[0];
			if (targets[file] == undefined) 
			{
				lastTarget = file.fileBridge.getFile as File;
				
				// Turn on optimize flag for release builds
				var optFlag:Boolean = pvo.buildOptions.optimize;
				if (release) pvo.buildOptions.optimize = true;
				var buildArgs:String = pvo.buildOptions.getArguments();
				pvo.buildOptions.optimize = optFlag;
				
				var dbg:String;
				if (release) dbg = " -debug=false";
				else dbg = " -debug=true";
				if (buildArgs.indexOf(" -debug=") > -1) dbg = "";
				
				var outputFile:File;
				if (release && pvo.swfOutput.path)
					outputFile = pvo.folderLocation.resolvePath("bin-release/"+ pvo.swfOutput.path.fileBridge.name).fileBridge.getFile as File;
				else if (pvo.swfOutput.path)
					outputFile = pvo.swfOutput.path.fileBridge.getFile as File;	
				
				var output:String;
				if (outputFile)
				{
					output = " -o " + pvo.folderLocation.fileBridge.getRelativePath(new FileLocation(outputFile.nativePath));
					if (outputFile.exists == false) FileUtil.createFile(outputFile);
				}
				
				var mxmlcStr:String = "mxmlc"
					+" -load-config+="+pvo.folderLocation.fileBridge.getRelativePath(pvo.config.file)
					+buildArgs
					+dbg
					+output;
				
				trace("mxmlc command: %s"+ mxmlcStr);
				return mxmlcStr;
			} 
			else 
			{
				var target:int = targets[file];
				return "compile "+target;
			}
		}
		
		private function send(msg:String):void 
		{
			debug("Sending to mxmlx: %s", msg);
			if (!fcsh) {
				queue.push(msg);
			} else {
				var input:IDataOutput = fcsh.standardInput;
				input.writeUTFBytes(msg+"\n");
			}
		}
		
		private function flush():void 
		{
			if (queue.length == 0) return;
			if (fcsh) {
				for (var i:int = 0; i < queue.length; i++) {
					send(queue[i]);
				}
				queue.length = 0;
			}
		}
		
		private function initShell():void 
		{
			if (fcsh) {
				startShell(false);
				exiting = true;
				reset();
			} else {
				startShell(true);
			}
		}
		
		private function startShell(start:Boolean):void 
		{
			if (start)
			{
				// stop running debug process for run/build if debug process in running
				if (!debugAfterBuild) GlobalEventDispatcher.getInstance().dispatchEvent(new CompilerEventBase(CompilerEventBase.STOP_DEBUG,false));
				
				fcsh = new NativeProcess();
				fcsh.addEventListener(ProgressEvent.STANDARD_OUTPUT_DATA, shellData);
				fcsh.addEventListener(ProgressEvent.STANDARD_ERROR_DATA, shellError);
				fcsh.addEventListener(IOErrorEvent.STANDARD_ERROR_IO_ERROR,shellError);
				fcsh.addEventListener(IOErrorEvent.STANDARD_OUTPUT_IO_ERROR,shellError);
				fcsh.addEventListener(NativeProcessExitEvent.EXIT, shellExit);
				fcsh.start(shellInfo);
				
				dispatcher.dispatchEvent(new StatusBarEvent(StatusBarEvent.PROJECT_BUILD_STARTED, currentProject.projectName, runAfterBuild ? "Launching " : "Building "));
				dispatcher.addEventListener(StatusBarEvent.PROJECT_BUILD_TERMINATE, onTerminateBuildRequest);
				flush();
			}
			else
			{
				if (!fcsh) return;
				if (fcsh.running) fcsh.exit();
				fcsh.removeEventListener(ProgressEvent.STANDARD_OUTPUT_DATA, shellData);
				fcsh.removeEventListener(ProgressEvent.STANDARD_ERROR_DATA, shellError);
				fcsh.removeEventListener(IOErrorEvent.STANDARD_ERROR_IO_ERROR,shellError);
				fcsh.removeEventListener(IOErrorEvent.STANDARD_OUTPUT_IO_ERROR,shellError);
				fcsh.removeEventListener(NativeProcessExitEvent.EXIT, shellExit);
				fcsh = null;
				
				dispatcher.dispatchEvent(new StatusBarEvent(StatusBarEvent.PROJECT_BUILD_ENDED));
				dispatcher.removeEventListener(StatusBarEvent.PROJECT_BUILD_TERMINATE, onTerminateBuildRequest);
			}
		}
		
		private function onTerminateBuildRequest(event:StatusBarEvent):void
		{
			if (fcsh && fcsh.running)
			{
				fcsh.exit(true);
			}
		}
		
		private function shellData(e:ProgressEvent):void 
		{
			if(fcsh)
			{
				var output:IDataInput = fcsh.standardOutput;
				var data:String = output.readUTFBytes(output.bytesAvailable);
				var match:Array;
				
				match = data.match(/fcsh: Target \d not found/);
				if (match)
				{
					error("Target not found. Try again.");
					targets = new Dictionary();
				}
				
				match = data.match(/fcsh: Assigned (\d) as the compile target id/);
				if (match && lastTarget) {
					var target:int = int(match[1]);
					targets[lastTarget] = target;
					
					debug("FSCH target: %s", target);
					
					lastTarget = null;
				}
				
				match = data.match(/.* bytes.*/);
				if (match) 
				{ // Successful compile
					// swfPath = match[1];
					
					print("Project Build Successfully");
					dispatcher.dispatchEvent(new RefreshTreeEvent((currentProject as AS3ProjectVO).swfOutput.path.fileBridge.parent));
					if (this.runAfterBuild && !this.debugAfterBuild)
					{
						testMovie();
					}
					else if (debugAfterBuild)
					{
						print("1 in MXMLCPlugin debugafterBuild");
						GlobalEventDispatcher.getInstance().dispatchEvent(new SWFLaunchEvent(SWFLaunchEvent.EVENT_UNLAUNCH_SWF, null));
						dispatcher.addEventListener(CompilerEventBase.RUN_AFTER_DEBUG,runAfterDebugHandler);
						dispatcher.dispatchEvent(
							new MXMLCPluginEvent(CompilerEventBase.POSTBUILD, (currentProject as AS3ProjectVO).buildOptions.customSDK ? (currentProject as AS3ProjectVO).buildOptions.customSDK : IDEModel.getInstance().defaultSDK)
						);
					}
					else if (AS3ProjectVO(currentProject).resourcePaths.length != 0)
					{
						resourceCopiedIndex = 0;
						getResourceCopied(currentProject as AS3ProjectVO, (currentProject as AS3ProjectVO).swfOutput.path.fileBridge.getFile as File);
					}
					
					reset();	
				}
				
				if (errors != "") 
				{
					compilerError(errors);
					targets = new Dictionary();
					errors = "";
				}
				
				if (data.charAt(data.length-1) == "\n") data = data.substr(0, data.length-1);
				debug("%s", data);
			}
			
		}
		
		private function runAfterDebugHandler(e:CompilerEventBase):void
		{
			debugAfterBuild = false;
			testMovie();
			dispatcher.removeEventListener(CompilerEventBase.RUN_AFTER_DEBUG,runAfterDebugHandler);
		}
		
		private function testMovie():void 
		{
			var pvo:AS3ProjectVO = currentProject as AS3ProjectVO;
			var swfFile:File = (currentProject as AS3ProjectVO).swfOutput.path.fileBridge.getFile as File;
			
			// before test movie lets copy the resource folder(s)
			// to debug folder if any
			if (pvo.resourcePaths.length != 0 && resourceCopiedIndex == 0)
			{
				getResourceCopied(pvo, swfFile);
				return;
			}
			else
			{
				resourceCopiedIndex = 0;
			}
			
			if (pvo.testMovie == AS3ProjectVO.TEST_MOVIE_CUSTOM) 
			{
				var customSplit:Vector.<String> = Vector.<String>(pvo.testMovieCommand.split(";"));
				var customFile:String = customSplit[0];
				var customArgs:String = customSplit.slice(1).join(" ").replace("$(ProjectName)", pvo.projectName).replace("$(CompilerPath)", currentSDK.nativePath);
				
				cmdLine.write(customFile+" "+customArgs, pvo.folderLocation);
			}
			else if (pvo.testMovie == AS3ProjectVO.TEST_MOVIE_AIR)
			{
				// Let SWFLauncher deal with playin' the swf
				dispatcher.dispatchEvent(
					new SWFLaunchEvent(SWFLaunchEvent.EVENT_LAUNCH_SWF, swfFile, pvo, currentSDK)
				);
			} 
			else 
			{
				// Let SWFLauncher runs the HTML file instead
				var htmlFile:File = pvo.folderLocation.resolvePath("bin-debug/"+ pvo.swfOutput.path.fileBridge.name.split(".")[0] +".html").fileBridge.getFile as File;
				if (htmlFile.exists)
				{
					dispatcher.dispatchEvent(
						new SWFLaunchEvent(SWFLaunchEvent.EVENT_LAUNCH_SWF, htmlFile, pvo) 
					);
				}
				else
				{
					dispatcher.dispatchEvent(
						new SWFLaunchEvent(SWFLaunchEvent.EVENT_LAUNCH_SWF, swfFile, pvo) 
					);
				}
			}
			
			currentProject = null;
		}
		
		private var resourceCopiedIndex:int;
		private function getResourceCopied(pvo:AS3ProjectVO, swfFile:File):void
		{
			var destination:File = swfFile.parent;
			var fl:FileLocation = pvo.resourcePaths[resourceCopiedIndex];
			(fl.fileBridge.getFile as File).addEventListener(Event.COMPLETE, onFileCopiedHandler, false, 0, true);
			(fl.fileBridge.getFile as File).copyToAsync(destination.resolvePath(fl.fileBridge.name), true);
			
			/*
			* @local
			*/
			function onFileCopiedHandler(event:Event):void
			{
				resourceCopiedIndex++;
				event.target.removeEventListener(Event.COMPLETE, onFileCopiedHandler);
				if (resourceCopiedIndex < pvo.resourcePaths.length) getResourceCopied(pvo, swfFile);
				else if (runAfterBuild || debugAfterBuild) 
				{
					dispatcher.dispatchEvent(new RefreshTreeEvent((currentProject as AS3ProjectVO).swfOutput.path.fileBridge.parent));
					testMovie();
				}
				else
				{
					dispatcher.dispatchEvent(new RefreshTreeEvent((currentProject as AS3ProjectVO).swfOutput.path.fileBridge.parent));
				}
			}
		}
		
		private function shellError(e:ProgressEvent):void 
		{
			if(fcsh)
			{
				var output:IDataInput = fcsh.standardError;
				var data:String = output.readUTFBytes(output.bytesAvailable);
				
				var syntaxMatch:Array;
				var generalMatch:Array;
				var initMatch:Array;
				
				syntaxMatch = data.match(/(.*?)\((\d*)\): col: (\d*) Error: (.*).*/);
				if (syntaxMatch) {
					var pathStr:String = syntaxMatch[1];
					var lineNum:int = syntaxMatch[2];
					var colNum:int = syntaxMatch[3];
					var errorStr:String = syntaxMatch[4];
					pathStr = pathStr.substr(pathStr.lastIndexOf("/")+1);
					errors += HtmlFormatter.sprintf("%s<weak>:</weak>%s \t %s\n",
						pathStr, lineNum, errorStr); 
				}
				
				//generalMatch = data.match(/(.*?): Error: (.*).*/);
				generalMatch = data.match(/(.*?):[\s*]* Error: (.*).*/);
				if (!syntaxMatch && generalMatch)
				{ 
					pathStr = generalMatch[1];
					errorStr  = generalMatch[2];
					pathStr = pathStr.substr(pathStr.lastIndexOf("/")+1);
					errors += HtmlFormatter.sprintf("%s: %s", pathStr, errorStr);
				}
				
				debug("%s", data);
				print(data);
				startShell(false);//new fix by D per Moon-84
			}
			targets = new Dictionary();
		}
		
		private function shellExit(e:NativeProcessExitEvent):void 
		{
			//debug("MCMLC exit code: %s", e.exitCode);
			reset();
			if (exiting) {
				exiting = false;
				startShell(true);
			}
		}
		
		protected function compilerWarning(...msg):void 
		{
			var text:String = msg.join(" ");
			var textLines:Array = text.split("\n");
			var lines:Vector.<TextLineModel> = Vector.<TextLineModel>([]);
			for (var i:int = 0; i < textLines.length; i++)
			{
				if (textLines[i] == "") continue;
				text = "<warning> ⚠  </warning>" + textLines[i]; 
				var lineModel:TextLineModel = new MarkupTextLineModel(text);
				lines.push(lineModel);
			}
			outputMsg(lines);
		}
		
		protected function compilerError(...msg):void 
		{
			var text:String = msg.join(" ");
			var textLines:Array = text.split("\n");
			var lines:Vector.<TextLineModel> = Vector.<TextLineModel>([]);
			for (var i:int = 0; i < textLines.length; i++)
			{
				if (textLines[i] == "") continue;
				text = "<error> ⚡  </error>" + textLines[i]; 
				var lineModel:TextLineModel = new MarkupTextLineModel(text);
				lines.push(lineModel);
			}
			outputMsg(lines);
			targets = new Dictionary();
		}
	}
}
