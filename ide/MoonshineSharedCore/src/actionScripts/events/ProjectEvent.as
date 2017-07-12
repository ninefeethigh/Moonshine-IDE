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
package actionScripts.events
{
	import flash.events.Event;
	
	import actionScripts.valueObjects.ProjectVO;
	
	public class ProjectEvent extends Event
	{
		public static const SHOW_PROJECT_VIEW:String = "showProjectViewEvent";
		public static const HIDE_PROJECT_VIEW:String = "hideProjectViewEvent";
		
		public static const ADD_PROJECT:String = "addProjectEvent";
		public static const REMOVE_PROJECT:String = "removeProjectEvent";
		
		public static const TREE_DATA_UPDATES: String = "TREE_DATA_UPDATES";
		public static const PROJECT_FILES_UPDATES: String = "PROJECT_FILES_UPDATES";
		
		public static const PROJECT_REFRESH: String = "PROJECT_REFRESH";
		public static const PROJECT_OPEN_REQUEST: String = "PROJECT_OPEN_REQUEST";
		public static const EVENT_IMPORT_FLASHBUILDER_PROJECT:String = "importFBProjectEvent";
		
		public static const LAST_OPENED_AS_FB_PROJECT:String = "LAST_OPENED_AS_FB_PROJECT";
		public static const LAST_OPENED_AS_FD_PROJECT:String = "LAST_OPENED_AS_FD_PROJECT";
		
		public static const FLEX_SDK_UDPATED: String = "FLEX_SDK_UDPATED";
		public static const FLEX_SDK_UDPATED_OUTSIDE: String = "FLEX_SDK_UDPATED_OUTSIDE";
		public static const SET_WORKSPACE: String = "SET_WORKSPACE";
		public static const WORKSPACE_UPDATED: String = "WORKSPACE_UPDATED";
		public static const ACCESS_MANAGER: String = "ACCESS_MANAGER";
		
		public var project:ProjectVO;
		public var anObject:Object;
		public var extras:Array;
		public var lastOpenedAs:String;
		
		public function ProjectEvent(type:String, project:Object=null, ...args)
		{
			if (project is ProjectVO) this.project = project as ProjectVO;
			else anObject = project;
			extras = args;
			super(type, false, false);
		}
		
	}
}