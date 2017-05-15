﻿////////////////////////////////////////////////////////////////////////////////
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
package actionScripts.ui.editor.text
{
	import actionScripts.valueObjects.Diagnostic;

	public class TextLineModel
	{
		protected var _text:String;
		protected var _meta:Vector.<int>;
		protected var _breakPoint:Boolean;
		protected var _width:Number = -1;
		protected var _traceLine:Boolean;
		protected var _diagnostics:Vector.<Diagnostic> = new <Diagnostic>[];
		
		public function set text(v:String):void
		{
			_text = v;
		}
		public function get text():String
		{
			return _text;
		}
		
		public function set meta(v:Vector.<int>):void
		{
			_meta = v;
		}
		public function get meta():Vector.<int>
		{
			return _meta;
		}
		
		public function set breakPoint(v:Boolean):void
		{
			_breakPoint = v;
		}
		public function get breakPoint():Boolean
		{
			return _breakPoint;
		}
		public function set traceLine(v:Boolean):void
		{
			_traceLine = v;
		}
		public function get traceLine():Boolean
		{
			return _traceLine;
		}

		public function set diagnostics(v:Vector.<Diagnostic>):void
		{
			_diagnostics = v;
		}
		public function get diagnostics():Vector.<Diagnostic>
		{
			return _diagnostics;
		}
		
		public function set width(v:Number):void
		{
			_width = v;
		}
		public function get width():Number
		{
			return _width;
		}
		
		public function get startContext():int
		{
			return _meta && _meta.length > 1 ? _meta[1] : 0;
		}
		
		public function get endContext():int
		{
			return _meta && _meta.length > 1 ? _meta[_meta.length-1] : 0;
		}
		
		public function TextLineModel(text:String)
		{
			this.text = text;
		}
		
		public function toString():String
		{
			return text;
		}
	}
}