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
package actionScripts.plugins.swflauncher
{
	import flash.desktop.NativeProcess;
	import flash.desktop.NativeProcessStartupInfo;
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.events.NativeProcessExitEvent;
	import flash.events.ProgressEvent;
	import flash.filesystem.File;
	import flash.filesystem.FileMode;
	import flash.filesystem.FileStream;
	import flash.net.URLRequest;
	import flash.net.navigateToURL;
	import flash.utils.IDataInput;
	
	import actionScripts.events.FilePluginEvent;
	import actionScripts.events.GlobalEventDispatcher;
	import actionScripts.plugin.PluginBase;
	import actionScripts.plugin.actionscript.as3project.vo.AS3ProjectVO;
	import actionScripts.plugin.core.compiler.CompilerEventBase;
	import actionScripts.plugin.settings.event.RequestSettingEvent;
	import actionScripts.plugins.as3project.mxmlc.MXMLCPlugin;
	import actionScripts.plugins.swflauncher.event.SWFLaunchEvent;
	import actionScripts.valueObjects.ProjectVO;
	import actionScripts.valueObjects.Settings;
	
	public class SWFLauncherPlugin extends PluginBase
	{	
		public static var RUN_AS_DEBUGGER: Boolean = false;
		
		override public function get name():String			{ return "SWF Launcher Plugin"; }
		override public function get author():String		{ return "Moonshine Project Team"; }
		override public function get description():String	{ return "Opens .swf files externally. Handles AIR launching via ADL."; }
		
		private var customProcess:NativeProcess ;
		private var currentAIRNamespaceVersion:String;
		
		override public function activate():void 
		{
			super.activate();
			dispatcher.addEventListener(SWFLaunchEvent.EVENT_LAUNCH_SWF, launchSwf);
			dispatcher.addEventListener(SWFLaunchEvent.EVENT_UNLAUNCH_SWF, unLaunchSwf);
			dispatcher.addEventListener(FilePluginEvent.EVENT_FILE_OPEN, handleOpenFile);
		}
		
		override public function deactivate():void 
		{
			super.deactivate();
			dispatcher.removeEventListener(SWFLaunchEvent.EVENT_LAUNCH_SWF, launchSwf);
			dispatcher.removeEventListener(FilePluginEvent.EVENT_FILE_OPEN, handleOpenFile);
			dispatcher.removeEventListener(SWFLaunchEvent.EVENT_UNLAUNCH_SWF, unLaunchSwf);
		}
		
		protected function handleOpenFile(event:FilePluginEvent):void
		{
			if (event.file.fileBridge.extension == "swf")
			{
				// Stop Moonshine from trying to open this file
				event.preventDefault();
				// Fake event
				launchSwf(new SWFLaunchEvent(SWFLaunchEvent.EVENT_LAUNCH_SWF, event.file.fileBridge.getFile as File));
			}
		}
		
		protected function launchSwf(event:SWFLaunchEvent):void
		{
			// Find project if we can (otherwise we can't open AIR swfs)
			if (!event.project) event.project = findProjectForFile(event.file);
			
			// Do we have an AIR project on our hands?
			if (event.project is AS3ProjectVO
				&& AS3ProjectVO(event.project).testMovie == AS3ProjectVO.TEST_MOVIE_AIR)
			{
				launchAIR(event.file, AS3ProjectVO(event.project), event.sdk);
			}
			else
			{
				// Open with default app
				launchExternal(event.file);
			}
		}
		
		// when user has already one session ins progress and tries to build/run the application again- close current session and start new one
		protected function unLaunchSwf(event:SWFLaunchEvent):void
		{
			if(customProcess){
				customProcess.exit(true);//Forcefully close running SWF
				addRemoveShellListeners(false);
				customProcess = null;
			}
		}
		
		protected function findProjectForFile(file:File):ProjectVO
		{
			for each (var project:ProjectVO in model.projects)
			{
				// See if we're part of this project
				if (file.nativePath.indexOf(project.folderLocation.fileBridge.nativePath) == 0)
				{
					return project;
				}
			}
			return null;
		}
		
		protected function launchAIR(file:File, project:AS3ProjectVO, sdk:File):void
		{
			if(customProcess)
			{
				customProcess.exit(true);
				addRemoveShellListeners(false);
				customProcess= null;
				
			}
			// Can't open files without an SDK set
			if (!sdk && !project.buildOptions.customSDK)
			{
				// Try to fetch default value from MXMLC plugin
				var event:RequestSettingEvent = new RequestSettingEvent(MXMLCPlugin, 'defaultFlexSDK');
				dispatcher.dispatchEvent(event);
				// None found, abort
				if (event.value == "" || event.value == null) return;
				
				// Default SDK found, let's use that
				sdk = new File(event.value.toString());
			}
			
			// Need project opened to run
			if (!project) return;
			
			var currentSDK:File = (project.buildOptions.customSDK) ? project.buildOptions.customSDK.fileBridge.getFile as File : sdk;
			
			var customInfo:NativeProcessStartupInfo = new NativeProcessStartupInfo();
			
			var executableFile:File;
			if( Settings.os == "win")
				executableFile = currentSDK.resolvePath("bin/adl.exe");
			else
				executableFile = currentSDK.resolvePath("bin/adl");
			//	customInfo.executable = executable;
			
			// Find air debug launcher
			print("Launch Applcation");
			
			// Guesstimate app-xml name
			var rootPath:String = File(project.folderLocation.fileBridge.getFile).getRelativePath(file.parent);
			var descriptorName:String = project.swfOutput.path.fileBridge.name.split(".")[0] +"-app.xml";
			var appXML:String = "src/"+ descriptorName;
			var descriptorFile:File = project.folderLocation.fileBridge.resolvePath(appXML).fileBridge.getFile as File;
			
			// in case /src/app-xml present update to bin-debug folder
			if (descriptorFile.exists)
			{
				appXML = rootPath +"/"+ descriptorName;
				descriptorFile.copyTo(project.folderLocation.resolvePath(appXML).fileBridge.getFile as File, true);
				descriptorFile =  project.folderLocation.resolvePath(appXML).fileBridge.getFile as File;
				var stream:FileStream = new FileStream();
				stream.open(descriptorFile, FileMode.READ);
				var data:String = stream.readUTFBytes(descriptorFile.size).toString();
				stream.close();
				
				// store namespace version for later probable use
				var firstNamespaceQuote:int = data.indexOf('"', data.indexOf("<application xmlns=")) + 1;
				var lastNamespaceQuote:int = data.indexOf('"', firstNamespaceQuote);
				currentAIRNamespaceVersion = data.substring(firstNamespaceQuote, lastNamespaceQuote);
				
				// replace if appropriate
				data = data.replace("[This value will be overwritten by Flash Builder in the output app.xml]", project.swfOutput.path.fileBridge.name);
				data = data.replace(currentAIRNamespaceVersion, "http://ns.adobe.com/air/application/"+ project.swfOutput.swfVersion +".0");
				if (data.indexOf("_") != -1)
				{
					// MOON-108
					// Since underscore char is not allowed in <id> we'll need to replace it
					var idFirstIndex:int = data.indexOf("<id>");
					var idLastIndex:int = data.indexOf("</id>");
					var dataIdValue:String = data.substring(idFirstIndex, idLastIndex+5);
					
					var pattern:RegExp = new RegExp(/(_)/g);
					var newID:String = dataIdValue.replace(pattern, "");
					data = data.replace(dataIdValue, newID);
				}
				
				stream = new FileStream();
				stream.open(descriptorFile, FileMode.WRITE);
				stream.writeUTFBytes(data);
				stream.close();
			}
			
			if (!descriptorFile.exists)
			{
				descriptorFile = project.folderLocation.resolvePath("application.xml").fileBridge.getFile as File;
				if (descriptorFile.exists) appXML = "application.xml";
			}
			
			//var executableFile: File = new File("C:\\Program Files\\Adobe\\Adobe Flash Builder 4.6\\sdks\\4.14\\bin\\adl.exe");
			customInfo.executable = executableFile;
			var processArgs:Vector.<String> = new Vector.<String>;               
			
			var isFlashDevelopProject: Boolean = (project.projectFile && project.projectFile.fileBridge.nativePath.indexOf(".as3proj") != -1) ? true : false;
			if (project.isMobile)
			{
				processArgs.push("-screensize");
				processArgs.push("iPhone");
				processArgs.push("-profile");
				processArgs.push("mobileDevice");
			}
			else
			{
				processArgs.push("-profile");
				processArgs.push("extendedDesktop");
			}
			
			processArgs.push(appXML);
			//processArgs.push(rootPath);
			
			customInfo.arguments = processArgs;
			
			customInfo.workingDirectory = new File(project.folderLocation.fileBridge.nativePath);
			customProcess = new NativeProcess();
			addRemoveShellListeners(true);
			customProcess.start(customInfo);
		}
		
		private function addRemoveShellListeners(add:Boolean):void 
		{
			if (add)
			{
				customProcess.addEventListener(ProgressEvent.STANDARD_OUTPUT_DATA, shellData);
				customProcess.addEventListener(ProgressEvent.STANDARD_ERROR_DATA, shellError);
				customProcess.addEventListener(IOErrorEvent.STANDARD_ERROR_IO_ERROR, shellError);
				customProcess.addEventListener(IOErrorEvent.STANDARD_OUTPUT_IO_ERROR, shellError);
				customProcess.addEventListener(NativeProcessExitEvent.EXIT, shellExit);
			}
			else
			{
				customProcess.removeEventListener(ProgressEvent.STANDARD_OUTPUT_DATA, shellData);
				customProcess.removeEventListener(ProgressEvent.STANDARD_ERROR_DATA, shellError);
				customProcess.removeEventListener(IOErrorEvent.STANDARD_ERROR_IO_ERROR, shellError);
				customProcess.removeEventListener(IOErrorEvent.STANDARD_OUTPUT_IO_ERROR, shellError);
				customProcess.removeEventListener(NativeProcessExitEvent.EXIT, shellExit);
			}
		}
		
		private function shellError(e:ProgressEvent):void 
		{
			if(customProcess)
			{
				var output:IDataInput = customProcess.standardError;
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
				}
				
				generalMatch = data.match(/(.*?): Error: (.*).*/);
				if (!syntaxMatch && generalMatch)
				{ 
					pathStr = generalMatch[1];
					errorStr  = generalMatch[2];
					pathStr = pathStr.substr(pathStr.lastIndexOf("/")+1);
					debug("%s", data);
				}
				else if (!RUN_AS_DEBUGGER)
				{
					debug("%s", data);
				}
					
			}
		}
		
		private function shellExit(e:NativeProcessExitEvent):void 
		{
			if(customProcess)
				GlobalEventDispatcher.getInstance().dispatchEvent(new CompilerEventBase(CompilerEventBase.STOP_DEBUG,false));
			//debug("SWF exit code: %s", e.exitCode);
		}
		
		private function shellData(e:ProgressEvent):void 
		{
			var output:IDataInput = customProcess.standardOutput;
			var data:String = output.readUTFBytes(output.bytesAvailable);
			
			var match:Array = data.match(/initial content not found/);
			if (match)
			{
				print("SWF source not found in application descriptor.");
				GlobalEventDispatcher.getInstance().dispatchEvent(new CompilerEventBase(CompilerEventBase.EXIT_FDB,false));
			}
			else if (data.match(/error while loading initial content/))
			{
				print('Error while loading SWF source.\nInvalid application descriptor: Unknown namespace: '+ currentAIRNamespaceVersion);
				GlobalEventDispatcher.getInstance().dispatchEvent(new CompilerEventBase(CompilerEventBase.EXIT_FDB,false));
			}
			else
			{
				debug("%s", data);
			}
		}
		protected function launchExternal(file:File):void
		{
			// Start with systems default handler for .swf filetype
			//file.openWithDefaultApplication();
			var request: URLRequest = new URLRequest(file.url);
			try 
			{
				navigateToURL(request, '_blank'); // second argument is target
			} catch (e:Error) {
				print(e.getStackTrace()+"Error");
			}
			
		}
	}
}