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
package actionScripts.locator
{
	import actionScripts.controllers.AddTabCommand;
	import actionScripts.controllers.CloseTabCommand;
	import actionScripts.controllers.DeleteFileCommand;
	import actionScripts.controllers.ICommand;
	import actionScripts.controllers.OpenFileCommand;
	import actionScripts.controllers.QuitCommand;
	import actionScripts.controllers.RenameFileFolderCommand;
	import actionScripts.controllers.SaveAsCommand;
	import actionScripts.controllers.SaveFileCommand;
	import actionScripts.controllers.TraceLineCommand;
	import actionScripts.events.AddTabEvent;
	import actionScripts.events.DeleteFileEvent;
	import actionScripts.events.GlobalEventDispatcher;
	import actionScripts.events.OpenFileEvent;
	import actionScripts.events.RenameFileFolderEvent;
	import actionScripts.ui.menu.MenuPlugin;
	import actionScripts.ui.tabview.CloseTabEvent;
	
	import flash.events.Event;
	
	public class IDEController
	{
		protected var commands:Object = {};

		public function IDEController() 
		{
			init();
		}

		public function init():void 
		{
			setupBindings();
			setupListener();
		}
		
		public function setupBindings():void 
		{	
			commands[CloseTabEvent.EVENT_CLOSE_TAB] = CloseTabCommand;
			commands[OpenFileEvent.OPEN_FILE] = OpenFileCommand;
			commands[AddTabEvent.EVENT_ADD_TAB] = AddTabCommand;
			
			commands[MenuPlugin.MENU_SAVE_AS_EVENT] = SaveAsCommand;
			commands[MenuPlugin.MENU_SAVE_EVENT] = SaveFileCommand; 
			commands[MenuPlugin.MENU_QUIT_EVENT] = QuitCommand;
			commands[DeleteFileEvent.EVENT_DELETE_FILE] = DeleteFileCommand;
			commands[RenameFileFolderEvent.RENAME_FILE_FOLDER] = RenameFileFolderCommand;
			commands[OpenFileEvent.TRACE_LINE]=          TraceLineCommand;
			
			/*commands[ChangeLineEncodingEvent.EVENT_CHANGE_TO_WIN] = 	ChangeLineEndingCommand;
			commands[ChangeLineEncodingEvent.EVENT_CHANGE_TO_UNIX] =	ChangeLineEndingCommand;
			commands[ChangeLineEncodingEvent.EVENT_CHANGE_TO_OS9] =		ChangeLineEndingCommand;*/
		}
		
		public function setupListener():void 
		{
			var ged:GlobalEventDispatcher = GlobalEventDispatcher.getInstance();
			for (var eventName:String in commands) 
			{
				ged.addEventListener(eventName, execCommand);
			}
		}
		
		public function execCommand(event:Event):void
		{
			var cmd:ICommand = new commands[event.type]();
			cmd.execute(event);
		}
		
	}
}