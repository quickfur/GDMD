/**
 * D port of dmd-script aka gdmd.
 */

module gdmd;

import std.algorithm : canFind;
import std.array : empty, front, popFront;
import std.conv;
import std.file;
import std.path;
import std.process;
import std.regex;
import std.stdio;
import std.string;

enum GdmdConfFile = "dmd.conf"; // FIXME: should rename


/**
 * Dummy exception object to implement exit().
 */
class ExitException : Exception {
    int status;
    this(int exitStatus = 0, string file = __FILE__, size_t line = __LINE__)
    {
        super("", file, line);
    }
}

/**
 * Convenient syntactic sugar for exiting program.
 */
void exit(int status=0, string file=__FILE__, size_t line=__LINE__) {
    throw new ExitException(status, file, line);
}

/**
 * Encapsulates current configuration state, so that we don't have to sprinkle
 * globals around everywhere.
 */
class Config
{
    string scriptPath;  /// path to this script
    string confPath;    /// path to dmd.conf
    string gdc;         /// path to GDC executable
    string linker;      /// path to linker

    int gdcMajVer, gdcMinVer; /// GDC major/minor version
    string machine;           /// output of gdc -dumpmachine

    string objExt;      /// extension of object files
    string execExt;     /// extension of executables

    string[] gdcFlags;  /// list of flags to pass to GDC
    string[] linkFlags; /// list of flags to pass to linker

    string outputDir;   /// path to prepend to output files
    string outputFile;  /// path to prepend to output files

    string[] sources;   /// list of source files
    string[] ddocs;     /// list of DDoc macro files

    bool keepPath;      /// whether to preserve source path for output files
    bool dontLink;      /// whether to skip linking stage
    bool debugMode;     /// debug flag
}


/**
 * Prints command-line usage.
 */
void printUsage()
{
    writeln(q"EOF
Documentation: http://dlang.org/
               http://www.gdcproject.org/
Usage:
  gdmd files.d ... { -switch }

  files.d        D source files
  \@cmdfile      read arguments from cmdfile
  -arch ...      pass an -arch ... option to gdc
  -c             do not link
  -cov           do code coverage analysis
  -D             generate documentation
  -Dddocdir      write documentation file to docdir directory
  -Dffilename    write documentation file to filename
  -d             silently allow deprecated features
  -dw            show use of deprecated features as warnings (default)
  -de            show use of deprecated features as errors (halt compilation)
  -debug         compile in debug code
  -debug=level   compile in debug code <= level
  -debug=ident   compile in debug code identified by ident
  -debuglib=lib  debug library to use instead of phobos
  -defaultlib=lib    default library to use instead of phobos
  -deps=filename write module dependencies to filename
  -f...          pass an -f... option to gdc
  -fall-sources  for every source file, semantically process each file preceding it
  -framework ... pass a -framework ... option to gdc
  -g             add symbolic debug info
  -gc            add symbolic debug info, pretend to be C
  -gs            always emit stack frame
  -gx            add stack stomp code
  -H             generate 'header' file
  -Hdhdrdir      write 'header' file to hdrdir directory
  -Hffilename    write 'header' file to filename
  --help         print help
  -Ipath         where to look for imports
  -ignore        ignore unsupported pragmas
  -inline        do function inlining
  -Jpath         where to look for string imports
  -Llinkerflag   pass linkerflag to link
  -lib           generate library rather than object files
  -m...          pass an -m... option to gdc
  -man           open web browser on manual page
  -map           generate linker .map file
  -noboundscheck turns off array bounds checking for all functions
  -O             optimize
  -o-            do not write object file
  -odobjdir      write object files to directory objdir
  -offilename    name output file to filename
  -op            do not strip paths from source file
  -pipe          use pipes rather than intermediate files
  -profile       profile runtime performance of generated code
  -property      enforce property syntax
  -quiet         suppress unnecessary messages
  -q,arg1,...    pass arg1, arg2, etc. to to gdc
  -release       compile release version
  -run srcfile args...   run resulting program, passing args
  -unittest      compile in unit tests
  -v             verbose
  -vdmd          print commands run by this script
  -version=level compile in version code >= level
  -version=ident compile in version code identified by ident
  -vtls          list all variables going into thread local storage
  -w             enable warnings
  -wi            enable informational warnings
  -X             generate JSON file
  -Xffilename    write JSON file to filename
EOF"
    );
}

/**
 * Convenience function for determining output filename given a source file.
 */
string src2out(Config cfg, string srcfile, string targetExt)
{
    string[] outpath;

    if (cfg.outputDir.length > 0)
        outpath ~= cfg.outputDir;

    if (cfg.keepPath)
        outpath ~= setExtension(srcfile, targetExt);
    else
        outpath ~= setExtension(baseName(srcfile), targetExt);

    return buildPath(outpath);
}

unittest
{
    auto cfg = new Config();
    assert(cfg.outputDir.length == 0);
    assert(cfg.src2out("prog.d", ".o") == "prog.o");

    cfg.outputDir = "subdir";
    assert(cfg.src2out("prog.d", ".o") == "subdir" ~ dirSeparator ~ "prog.o");
}

unittest
{
    auto cfg = new Config();
    cfg.keepPath = false;
    assert(cfg.src2out("subdir/prog.d", ".o") == "prog.o");

    cfg.keepPath = true;
    assert(cfg.src2out("subdir/prog.d", ".o") == "subdir/prog.o");

    cfg.outputDir = "objdir";
    assert(cfg.src2out("subdir/prog.d", ".o") == "objdir/subdir/prog.o");
}

/**
 * Returns object filename corresponding to a given source.
 * Params: srcfile = source filename.
 * Returns: object filename.
 */
string src2obj(Config cfg, string srcfile)
{
    return src2out(cfg, srcfile, cfg.objExt);
}

unittest
{
    auto cfg = new Config();
    cfg.objExt = ".obj";
    assert(cfg.src2obj("prog.d") == "prog.obj");
}

/**
 * Returns executable filename corresponding to a given source.
 * Params: srcfile = source filename.
 * Returns: executable filename.
 */
string src2exe(Config cfg, string srcfile)
{
    // Note: there's a bug in setExtension when cfg.execExt is empty (e.g. on
    // Posix): it appends a stray dot to the resulting filename. So we replace
    // the extension manually here.
    return stripExtension(srcfile) ~ cfg.execExt;
}

unittest
{
    auto cfg = new Config();
    cfg.execExt = ".exe";
    assert(cfg.src2exe("prog.d") == "prog.exe");
}

unittest
{
    auto cfg = new Config();
    cfg.execExt = "";
    assert(cfg.src2exe("subdir/prog.d") == "subdir/prog");
}

/**
 * Searches $PATH to find the given program.
 */
string findBin(string program)
{
    auto binpaths = environment["PATH"];
    foreach (path; binpaths.split(pathSeparator)) {
        auto exe = buildNormalizedPath(path, program);
        if (exists(exe)) {
            return exe;
        }
    }
    return "";
}

/**
 * Finds the path to this program.
 */
string findScriptPath(string argv0)
out(path) { assert(path.length != 0); }
body
{
    return findBin(argv0);
}

/**
 * Finds GDC.
 */
string findGDC()
out(path) { assert(path.length != 0); }
body
{
    auto gdc = findBin("gdc");
    if (gdc.length == 0)
        throw new Exception("Unable to find gdc executable");

    return gdc;
}

/**
 * Finds dmd.conf in:
 * - current working directory
 * - directory specified by the HOME environment variable
 * - directory gdmd resides in
 * - /etc directory
 */
string findDmdConf(Config cfg) {
    auto confPaths = [
        ".", environment["HOME"], cfg.scriptPath, "/etc"
    ];

    foreach (path; confPaths) {
        auto confPath = buildPath(path, GdmdConfFile);
        if (exists(confPath)) {
            cfg.confPath = confPath;
            return confPath;
        }
    }
    return null;
}

/**
 * Loads environment settings from GdmdConfFile and stores them in the
 * environment.
 */
void readDmdConf(Config cfg) {
    auto dmdConf = findDmdConf(cfg);
    if (dmdConf) {
        auto lines = File(dmdConf).byLine();
        int linenum = 1;

        // Look for Environment section
        typeof(match(lines.front, `.`)) m;
        while (!lines.empty && !(m = match(lines.front,
                                           `^\s*\[\s*Environment\s*\]\s*$`)))
        {
            lines.popFront();
            linenum++;
        }

        if (m) {
            lines.popFront();

            for (; !lines.empty; lines.popFront(), linenum++) {
                // Ignore comments and empty lines
                if (match(lines.front, `^(\s*;|\s*$)`))
                    continue;

                // Check for proper syntax
                m = match(lines.front, `^\s*(\S+?)\s*=\s*(.*)\s*$`);
                if (!m)
                    throw new Exception(format("Syntax error in %s line %d",
                                               dmdConf, linenum));

                string var = m.captures[1].idup;
                string val = m.captures[2].idup;

                // The special name %@P% is replaced with the path to
                // GdmdConfFile
                val = replace(val, regex(`%\@P%`, "g"), cfg.confPath);

                // Names enclosed by %% are searched for in the existing
                // environment and inserted.
                val = replace!((Captures!string m) => environment[m.hit.idup])
                              (val, regex(`%(\S+?)%`, "g"));

                debug writefln("[conf] %s='%s'", var, val);
                environment[var] = val;
            }
        }
    }
}

/**
 * Invokes GDC to retrieve settings.
 */
void getGdcSettings(Config cfg)
{
    auto run(string[] args) {
        auto rc = execute(args);
        if (rc.status != 0)
            throw new Exception("Failed to invoke %s: %d (%s)"
                                .format(args[0], rc.status, rc.output));
        return rc;
    }

    // Read GDC major/minor version
    {
        auto rc = run([cfg.gdc, "-dumpversion"]);
        auto m = match(rc.output, `^(\d+)\.(\d+)`);
        cfg.gdcMajVer = to!int(m.captures[1]);
        cfg.gdcMinVer = to!int(m.captures[2]);

        debug writefln("[gdc] majver=%d minver=%d", cfg.gdcMajVer,
                       cfg.gdcMinVer);
    }

    // Read target machine type
    version(none)
    {
        auto rc = run([cfg.gdc, "-dumpmachine"]);
        cfg.machine = chomp(rc.output);
    }
}

/**
 * Initializes GDMD default configuration values, read config files, etc..
 * Returns: Config object that captures all of these settings.
 */
Config init(string[] args)
{
    auto cfg = new Config();
    cfg.scriptPath = findScriptPath(args[0]);
    cfg.gdc = findGDC();
    cfg.linker = cfg.gdc;

    debug writeln("[conf] scriptPath = ", cfg.scriptPath);
    debug writeln("[conf] gdc = ", cfg.gdc);

    readDmdConf(cfg);
    getGdcSettings(cfg);

    version(Windows) {
        cfg.objExt = ".obj";
        cfg.execExt = ".exe";
    }

    version(Posix) {
        cfg.objExt = ".o";
        cfg.execExt = "";
    }

    return cfg;
}

/**
 * Parse command-line arguments and sets up the appropriate settings in the
 * Config object.
 */
void parseArgs(Config cfg, string[] _args)
{
    auto args = _args;
    while (!args.empty) {
        auto arg = args.front;

        if (arg == "-arch") {
            args.popFront();
            // TBD: bounds check
            cfg.gdcFlags ~= [ "-arch", args.front ];
        } else if (arg == "-c") {
            cfg.dontLink = true;
        } else if (arg == "-cov") {
            cfg.gdcFlags ~= [ "-fprofile-arcs", "-ftest-coverage" ];
        } else if (arg == "-D") {
            // TBD
        } else if (auto m = match(arg, `-Dd(.*)$`)) {
            // TBD
        } else if (auto m = match(arg, `-Df(.*)$`)) {
            // TBD
        } else if (arg == "-d") {
            cfg.gdcFlags ~= "-Wno-deprecated";
        } else if (arg == "-de") {
            cfg.gdcFlags ~= [ "-Wdeprecated", "-Werror" ];
        } else if (arg == "-dw") {
            cfg.gdcFlags ~= "-Wdeprecated";
        } else if (auto m=match(arg, `^-debug(?:=(.*))?$`)) {
            cfg.gdcFlags ~= (m.captures[1].length > 0) ?
                                "-fdebug="~m.captures[1] : "-fdebug";
        } else if (auto m=match(arg, `^-debuglib=(.*)$`)) {
            cfg.linkFlags ~= [ "-debuglib", m.captures[1] ];
        } else if (match(arg, `^-debug.*$`)) {
            throw new Exception("unrecognized switch '%s'".format(arg));
        } else if (auto m=match(arg, `^-defaultlib=(.*)$`)) {
            cfg.linkFlags ~= [ "-defaultlib", m.captures[1] ];
        } else if (auto m=match(arg, `^-deps=(.*)$`)) {
            cfg.gdcFlags ~= (m.captures[1].length > 0) ?
                                "-fdeps=" ~ m.captures[1] : "-fdeps";
        } else if (arg == "-g" || arg == "-gc") {
            cfg.debugMode = true;
            cfg.gdcFlags ~= "-g";
        } else if (arg == "-gs") {
            cfg.gdcFlags ~= "-fno-omit-frame-pointer";
        } else if (arg == "-gt") {
            throw new Exception("use -profile instead of -gt");
        } else if (arg == "-gx") {
            cfg.gdcFlags ~= "-fstack-protector";
        } else if (arg == "-H") {
            // TBD
        } else if (auto m=match(arg, regex(`-Hd(.*)$`))) {
            // TBD
        } else if (auto m=match(arg, regex(`-Hf(.*)$`))) {
            // TBD
        } else if (arg == "--help") {
            printUsage();
            exit(0);
        } else if (arg == "-framework") {
            args.popFront();
            // TBD: bounds check
            cfg.linkFlags ~= [ "-framework", args.front ];
        } else if (arg == "-ignore") {
            cfg.gdcFlags ~= "-fignore-unknown-pragmas";
        } else if (arg == "-property") {
            cfg.gdcFlags ~= "-fproperty";
        } else if (arg == "-inline") {
            cfg.gdcFlags ~= "-finline-functions";
        } else if (auto m=match(arg, `^-I(.*)$`)) {
            cfg.gdcFlags ~= ["-I", expandTilde(m.captures[1])];
        } else if (auto m=match(arg, `^-J(.*)$`)) {
            cfg.gdcFlags ~= ["-J", expandTilde(m.captures[1])];
        } else if (auto m=match(arg, `^-L(.*)$`)) {
            cfg.linkFlags ~= "-Wl," ~ m.captures[1];
        } else if (arg == "-lib") {
            // TBD
        } else if (arg == "-O") {
            cfg.gdcFlags ~= ["-O3"];
            // FIXME: this is rather ugly
            if (!canFind(_args, "-inline"))
                cfg.gdcFlags ~= ["-fno-inline-functions"];
        } else if (arg == "-o-") {
            cfg.gdcFlags ~= ["-fsyntax-only"];
            cfg.dontLink = true;
        } else if (auto m=match(arg, `^-od(.*)$`)) {
            cfg.outputDir = m.captures[1];
        } else if (auto m=match(arg, `^-of(.*)$`)) {
            cfg.outputDir = dirName(m.captures[1]);
            cfg.outputFile = m.captures[1];
        } else if (arg == "-op") {
            cfg.keepPath = true;
        } else if (match(arg, regex(`\.d$`, "i"))) {
            cfg.sources ~= arg;
        } else if (match(arg, regex(`\.ddoc$`, "i"))) {
            cfg.ddocs ~= arg;
        } else {
            // TBD: append to list of obj files
        }

        args.popFront();
    }

    debug writeln("[conf] gdc flags = ", cfg.gdcFlags);
    debug writeln("[conf] link flags = ", cfg.linkFlags);
}

/**
 * Compiles the given source files.
 */
void compile_only(Config cfg)
{
    foreach (srcfile; cfg.sources) {
        auto objfile = cfg.src2obj(srcfile);

        // If target directory doesn't exist yet, create it.
        auto objdir = dirName(objfile);
        if (!exists(objdir)) {
            debug writefln("[exec] mkdirRecurse(%s)", objdir);
            mkdirRecurse(objdir);
        }

        // Invoke compiler
        auto cmd = [ cfg.gdc ] ~ cfg.gdcFlags ~ [
            "-c", srcfile, "-o", objfile
        ];
        debug writeln("[exec] ", cmd.join(" "));
        auto rc = execute(cmd);
        if (rc.status != 0)
            throw new Exception("Compile of %s failed: %s"
                                .format(srcfile, rc.output));
    }
}

/**
 * Determine output file given current configuration.
 */
string determineOutputFile(Config cfg)
{
    assert(cfg.sources.length >= 1);
    return (cfg.outputFile.length > 0) ? cfg.outputFile
                                       : cfg.src2exe(baseName(cfg.sources[0]));
}

unittest
{
    // If no explicit output file is given, use first .d file as basename.
    auto cfg = new Config();
    cfg.sources = ["test.d", "module.d"];
    cfg.execExt = ".exe";
    assert(cfg.determineOutputFile() == "test.exe");

    // DMD appears to only use -od for object files, not the final executable.
    // So outputDir shouldn't affect the results.
    cfg.outputDir = "subdir";
    assert(cfg.determineOutputFile() == "test.exe");

    // If output filename is specified, we should be using that instead
    cfg.outputFile = "prog.exe";
    assert(cfg.determineOutputFile() == "prog.exe");

    // That should still hold if outputDir wasn't specified
    cfg.outputDir = "";
    assert(cfg.determineOutputFile() == "prog.exe");
}

unittest
{
    // Sigh, dmd's path handling is very quirky.
    {
        auto cfg = new Config();
        cfg.parseArgs(["-ofprog", "src/test.d"]);
        assert(cfg.determineOutputFile() == "prog");
    }
    {
        auto cfg = new Config();
        cfg.parseArgs(["-odobjdir", "src/test.d"]);
        assert(cfg.determineOutputFile() == "test");
    }
    {
        auto cfg = new Config();
        cfg.parseArgs(["-ofobjdir/prog", "src/test.d"]);
        assert(cfg.determineOutputFile() == "objdir/prog");
    }
}

/**
 * Compiles and links the given sources files into the final executable.
 */
void compile_and_link(Config cfg)
{
	/*
     * Construct link command
     */
    auto cmd = [ cfg.linker ] ~ cfg.gdcFlags ~ cfg.linkFlags;

    // Collect all source files.
    foreach (srcfile; cfg.sources) {
        cmd ~= srcfile;
    }

    // Create target directory if it doesn't exist yet.
    auto exefile = cfg.determineOutputFile();
    auto exedir = dirName(exefile);
    if (!exists(exedir))
        mkdirRecurse(exedir);

    // Specify output file
    cmd ~= [ "-o", exefile ];

    /*
     * Invoke linker
     */
    debug writeln("[exec] ", cmd.join(" "));
    auto rc = execute(cmd);
    if (rc.status != 0)
        throw new Exception("Compile and link failed: %s".format(rc.output));
}

/**
 * Main program
 */
int main(string[] args)
{
    try {
        auto cfg = init(args);
        parseArgs(cfg, args[1..$]);

        if (cfg.sources.length == 0) {
            printUsage();
            exit(0);
        }

	if (cfg.dontLink) {
		compile_only(cfg);
	}
	else {
		compile_and_link(cfg);
	}

        return 0;
    } catch(ExitException e) {
        return e.status;
    } catch(Exception e) {
        writeln(e.msg);
        return 1;
    }
}


// vim:set ts=4 sw=4 et:
