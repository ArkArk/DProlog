
import dprolog.engine.Engine;

import std.stdio;
import std.conv;
import std.string;
import std.getopt;

void main(string[] args) {

  string filePath;
  bool verbose;
  auto opt = getopt(
    args,
    "file", &filePath,
    "verbose", &verbose
  );

  Engine engine = new Engine;
  engine.setVerbose(verbose);

  // read a file
  if (!filePath.empty) {
    engine.readFile(filePath.to!dstring);
    while(!engine.emptyMessage) engine.showMessage;
  }

  while(!engine.isHalt) {
    writeln;
    write("?- ");
    stdout.flush();
    string query = readln.chomp;
    engine.execute("?- "d ~ query.to!dstring);
    while(!engine.emptyMessage) engine.showMessage;
  }
}
