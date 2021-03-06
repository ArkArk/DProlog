module dprolog.engine.Messenger;

import dprolog.util.Message;
import dprolog.util.Singleton;

import std.stdio;
import std.container : DList;

alias Messenger = Singleton!Messenger_;

private class Messenger_ {

private:
  DList!Message _messageList;

public:
  this() {
    clear();
  }

  @property bool empty() {
    return _messageList.empty;
  }

  void write(Message msg) {
    msg.write;
    stdout.flush;
  }

  void writeln(Message msg) {
    msg.writeln;
    stdout.flush;
  }

  void add(Message msg) {
    _messageList.insertBack(msg);
  }

  void show() in(!empty) do {
    _messageList.front.writeln;
    _messageList.removeFront;
    stdout.flush;
  }

  void showAll() {
    while(!empty) {
      show();
    }
  }

  void clear() {
    _messageList.clear();
  }

}
