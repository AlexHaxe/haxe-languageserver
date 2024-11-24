package haxeLanguageServer.features.haxe.refactoring;

import haxe.Exception;
import haxe.PosInfos;
import haxe.display.Server.ServerMethods;
import haxe.io.Path;
import refactor.cache.IFileCache;
import refactor.cache.MemCache;
import refactor.discover.FileContentType;
import refactor.discover.FileList;
import refactor.discover.NameMap;
import refactor.discover.TraverseSources;
import refactor.discover.TypeList;
import refactor.discover.UsageCollector;
import refactor.discover.UsageContext;
import refactor.refactor.CanRefactorContext;
import refactor.refactor.RefactorContext;
import refactor.rename.CanRenameContext;
import refactor.rename.RenameContext;
import tokentree.TokenTree;

using haxeLanguageServer.helper.PathHelper;

class RefactorCache {
	final context:Context;

	public final cache:IFileCache;
	public final typer:LanguageServerTyper;
	public final converter:Haxe3DisplayOffsetConverter;
	public final usageCollector:UsageCollector;
	public final nameMap:NameMap;
	public final fileList:FileList;
	public final typeList:TypeList;
	public var classPaths:Array<String>;

	public function new(context:Context) {
		this.context = context;

		cache = new MemCache();
		converter = new Haxe3DisplayOffsetConverter();
		typer = new LanguageServerTyper(context);
		usageCollector = new UsageCollector();
		nameMap = new NameMap();
		fileList = new FileList();
		typeList = new TypeList();
		classPaths = [];
		initClassPaths();
	}

	function clearCache() {
		cache.clear();
		nameMap.clear();
		fileList.clear();
		typeList.clear();
	}

	public function initClassPaths() {
		clearCache();
		if (!context.haxeServer.supports(ServerMethods.Contexts)) {
			initFromSetting();
			return;
		}
		context.callHaxeMethod(ServerMethods.Contexts, null, null, function(contexts) {
			classPaths = [];
			for (ctx in contexts) {
				if (ctx?.desc == "after_init_macros") {
					for (path in ctx.classPaths) {
						if (path == "") {
							continue;
						}
						if (Path.isAbsolute(path)) {
							continue;
						}
						classPaths.push(path);
					}
					break;
				}
			}
			if (classPaths.length <= 0) {
				initFromSetting();
				return "";
			}
			#if debug
			trace("[RefactorCache] detected classpaths: " + classPaths);
			#end

			init();
			return "";
		}, (err) -> initFromSetting());
	}

	function initFromSetting() {
		classPaths = ["src", "source", "Source", "test", "tests"];
		if (context.config.user.renameSourceFolders != null) {
			classPaths = context.config.user.renameSourceFolders;
		}
		init();
	}

	function init() {
		var endProgress = context.startProgress("Building Refactoring Cache…");

		final usageContext:UsageContext = makeUsageContext();
		typer.typeList = usageContext.typeList;

		final workspacePath = context.workspacePath.normalize();
		final srcFolders = classPaths.map(f -> Path.join([workspacePath.toString(), f]));

		try {
			TraverseSources.traverseSources(srcFolders, usageContext);
			usageContext.usageCollector.updateImportHx(usageContext);
		} catch (e:Exception) {
			#if debug
			trace("failed to updateFileCache: " + e);
			#end
		}

		endProgress();
	}

	public function updateFileCache() {
		init();
	}

	public function updateSingleFileCache(uri:String) {
		final usageContext:UsageContext = makeUsageContext();
		usageContext.fileName = uri;
		try {
			TraverseSources.collectIdentifierData(usageContext);
		} catch (e:Exception) {
			#if debug
			trace("failed to updateSingleFileCache: " + e);
			#end
		}
	}

	public function invalidateFile(uri:String) {
		cache.invalidateFile(uri, nameMap, typeList);
		fileList.removeFile(uri);
	}

	public function makeUsageContext():UsageContext {
		return {
			fileReader: readFile,
			fileName: "",
			file: null,
			usageCollector: usageCollector,
			nameMap: nameMap,
			fileList: fileList,
			typeList: typeList,
			type: null,
			cache: cache
		};
	}

	public function makeCanRenameContext(doc:HaxeDocument, filePath:FsPath, position:Position):CanRenameContext {
		return {
			nameMap: nameMap,
			fileList: fileList,
			typeList: typeList,
			what: {
				fileName: filePath.toString(),
				toName: "",
				pos: converter.characterOffsetToByteOffset(doc.content, doc.offsetAt(position))
			},
			verboseLog: function(text:String, ?pos:PosInfos) {
				#if debug
				trace('[canRename] $text');
				#end
			},

			typer: typer,
			fileReader: readFile,
			converter: converter.byteOffsetToCharacterOffset,
		};
	}

	public function makeRenameContext(doc:HaxeDocument, filePath:FsPath, position:Position, newName:String, editList:EditList):RenameContext {
		return {
			nameMap: nameMap,
			fileList: fileList,
			typeList: typeList,
			what: {
				fileName: filePath.toString(),
				toName: newName,
				pos: converter.characterOffsetToByteOffset(doc.content, doc.offsetAt(position))
			},
			forRealExecute: true,
			docFactory: (filePath:String) -> new EditDoc(new FsPath(filePath), editList, context, converter),
			verboseLog: function(text:String, ?pos:PosInfos) {
				#if debug
				trace('[rename] $text');
				#end
			},

			typer: typer,
			fileReader: readFile,
			converter: converter.byteOffsetToCharacterOffset,
		};
	}

	public function makeCanRefactorContext(doc:Null<HaxeDocument>, range:Range):Null<CanRefactorContext> {
		if (doc == null) {
			return null;
		}
		return {
			nameMap: nameMap,
			fileList: fileList,
			typeList: typeList,
			what: {
				fileName: doc.uri.toFsPath().toString(),
				posStart: converter.characterOffsetToByteOffset(doc.content, doc.offsetAt(range.start)),
				posEnd: converter.characterOffsetToByteOffset(doc.content, doc.offsetAt(range.end))
			},
			verboseLog: function(text:String, ?pos:PosInfos) {
				#if debug
				trace('[Refactor] $text');
				#end
			},
			typer: typer,
			fileReader: readFile,
			converter: converter.byteOffsetToCharacterOffset,
		};
	}

	public function makeRefactorContext(doc:Null<HaxeDocument>, range:Range, editList:EditList):Null<RefactorContext> {
		if (doc == null) {
			return null;
		}
		return {
			nameMap: nameMap,
			fileList: fileList,
			typeList: typeList,
			what: {
				fileName: doc.uri.toFsPath().toString(),
				posStart: converter.characterOffsetToByteOffset(doc.content, doc.offsetAt(range.start)),
				posEnd: converter.characterOffsetToByteOffset(doc.content, doc.offsetAt(range.end))
			},
			verboseLog: function(text:String, ?pos:PosInfos) {
				#if debug
				trace('[refactor] $text');
				#end
			},
			typer: typer,
			fileReader: readFile,
			forRealExecute: true,
			docFactory: (filePath:String) -> new EditDoc(new FsPath(filePath), editList, context, converter),
			converter: converter.byteOffsetToCharacterOffset,
		};
	}

	function readFile(path:String):FileContentType {
		var fsPath = new FsPath(path);
		var doc:Null<HaxeDocument> = context.documents.getHaxe(fsPath.toUri());
		if (doc == null) {
			return simpleFileReader(path);
		}
		var root:Null<TokenTree> = doc?.tokens?.tree;
		if (root != null) {
			return Token(root, doc.content);
		}
		return Text(doc.content);
	}
}
