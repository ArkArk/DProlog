module dprolog.engine.Executor;

import dprolog.data.token;
import dprolog.data.Term;
import dprolog.data.Clause;
import dprolog.data.Variant;
import dprolog.util.Message;
import dprolog.converter.Converter;
import dprolog.converter.Lexer;
import dprolog.converter.Parser;
import dprolog.converter.ClauseBuilder;
import dprolog.util.functions;
import dprolog.util.Maybe;
import dprolog.util.Either;
import dprolog.util.Singleton;
import dprolog.engine.Engine;
import dprolog.engine.Messenger;
import dprolog.engine.builtIn.BuiltInCommand;
import dprolog.engine.builtIn.BuiltInPredicate;
import dprolog.engine.Evaluator;
import dprolog.engine.UnificationUF;
import dprolog.core.Linenoise;

import std.format;
import std.conv;
import std.range;
import std.array;
import std.algorithm;
import std.functional;
import std.typecons;
import std.concurrency : Generator, yield;

alias UnificateResult = Tuple!(bool, "found", bool, "isCutted");

class CallUnificateNotifier {}
alias UnificateYield = Either!(CallUnificateNotifier, UnificationUF);

alias Executor = Singleton!Executor_;

private class Executor_ {

private:
  Lexer _lexer;
  Parser _parser;
  ClauseBuilder _clauseBuilder;

  Clause[] _storage;

public:
  this() {
    _lexer = new Lexer;
    _parser = new Parser;
    _clauseBuilder = new ClauseBuilder;
    clear();
  }

  void execute(dstring src) in(!Engine.isHalt) do {
    toClauseList(src).apply!((clauseList) {
      foreach(clause; clauseList) {
        if (Engine.isHalt) break;
        executeClause(clause);
      }
    });
  }

  void clear() {
    _lexer.clear;
    _parser.clear;
    _clauseBuilder.clear;
    _storage = [];
  }

private:
  Maybe!(Clause[]) toClauseList(dstring src) {
    auto convert(S, T)(Converter!(S, T) converter) {
      return (S src) {
        converter.run(src);
        if (converter.hasError) {
          Messenger.add(converter.errorMessage);
          return None!T;
        }
        return converter.get.Just;
      };
    }
    return Just(src).bind!(
      a => convert(_lexer)(a)
    ).bind!(
      a => convert(_parser)(a)
    ).bind!(
      a => convert(_clauseBuilder)(a)
    );
  }

  void executeClause(Clause clause) {
    if (Engine.verboseMode) {
      Messenger.writeln(VerboseMessage(format!"execute: %s"(clause)));
    }
    clause.castSwitch!(
      (Fact fact)   => executeFact(fact),
      (Rule rule)   => executeRule(rule),
      (Query query) => executeQuery(query)
    );
  }

  void executeFact(Fact fact) {
    _storage ~= fact;
  }

  void executeRule(Rule rule) {
    _storage ~= rule;
  }

  void executeQuery(Query query) {
    if (BuiltInCommand.traverse(query.first)) {
      // when matching a built-in pattern
      return;
    }

    Variant first, second;
    UnificationUF unionFind = buildUnionFind(query, first, second);

    auto generator = new Generator!UnificateYield({
      unificate(first, unionFind);
    }, 1<<20);

    string[] rec(Variant v, UnificationUF uf, ref bool[string] exists) {
      if (v.isVariable && !v.term.token.isUnderscore) {
        Variant root = uf.root(v);
        string lexeme = v.term.to!string;
        if (lexeme in exists) {
          return [];
        } else {
          exists[lexeme] = true;
        }
        return [
          lexeme,
          "=",
          {
            Term f(Variant var) {
              if (var.isVariable) {
                auto x = uf.root(var);
                return x == var ? x.term : x.pipe!f;
              } else {
                return new Term(
                  var.term.token,
                  var.children.map!f.array
                );
              }
            }

            return root.pipe!f.to!string;
          }()
        ].join(" ").only.array;
      } else {
        return v.children.map!(u => rec(u, uf, exists)).join.array;
      }
    }

    void eatYields() {
      while(!generator.empty) {
        auto result = generator.front;
        if (result.isLeft) {
          generator.popFront;
        } else {
          break;
        }
      }
    }

    eatYields();

    if (generator.empty) {
      Messenger.showAll();
      Messenger.writeln(DefaultMessage("false."));
    } else {
      while(true) {
        assert(!generator.empty);
        auto result = generator.front;
        generator.popFront;
        assert(result.isRight);

        auto uf = result.right;

        Messenger.showAll();
        bool[string] exists;
        string answer = rec(first, uf, exists).join(", ");
        if (answer.empty) answer = "true";

        if (generator.empty) {
          Messenger.writeln(DefaultMessage(answer ~ "."));
          break;
        }

        auto line = Linenoise.nextLine(answer ~ "; ");
        if (line.isJust) {
        } else {
          Messenger.writeln(InfoMessage("%  Execution Aborted"));
          break;
        }

        eatYields();
        if (generator.empty) {
          Messenger.writeln(ErrorMessage("false."));
          break;
        }
      }
    }
  }

  // fiber function
  UnificateResult unificate(Variant variant, UnificationUF unionFind) {
    yieldLeft();

    variant = unionFind.root(variant);
    const Term term = variant.term;
    UnificateResult unificateResult = UnificateResult(false, false);

    if (term.token == Operator.comma) {
      // conjunction
      auto gen = new Generator!UnificateYield({
        auto r = unificate(variant.children.front, unionFind);
        unificateResult.isCutted |= r.isCutted;
      }, 1<<20);
      foreach(result; gen) {
        if (result.isLeft) continue;
        auto uf = result.right;
        auto r = unificate(variant.children.back, uf);
        unificateResult.isCutted |= r.isCutted;
        unificateResult.found |= r.found;
      }
    } else if (term.token == Operator.semicolon) {
      // disjunction
      if (!unificateResult.isCutted) {
        auto r = unificate(variant.children.front, unionFind);
        unificateResult.isCutted |= r.isCutted;
        unificateResult.found |= r.found;
      }
      if (!unificateResult.isCutted) {
        auto r = unificate(variant.children.back, unionFind);
        unificateResult.isCutted |= r.isCutted;
        unificateResult.found |= r.found;
      }
    } else if (term.token == Operator.equal) {
      // unification
      UnificationUF newUnionFind = unionFind.clone;
      if (match(variant.children.front, variant.children.back, newUnionFind)) {
        yieldRight(newUnionFind);
        unificateResult.found |= true;
      }
    } else if (term.token == Operator.equalEqual) {
      // equality comparison
      if (unionFind.same(variant.children.front, variant.children.back)) {
        yieldRight(unionFind);
        unificateResult.found |= true;
      }
    } else if (term.token == Operator.eval) {
      // arithmetic evaluation
      auto result = Evaluator.calc(variant.children.back, unionFind);
      if (result.isLeft) {
        Messenger.add(result.left);
      } else {
        Number y = result.right;
        Variant xVar = unionFind.root(variant.children.front);
        xVar.term.token.castSwitch!(
          (Variable x) {
            UnificationUF newUnionFind = unionFind.clone;
            Variant yVar = new Variant(-1, new Term(y, []), []);
            newUnionFind.add(yVar);
            newUnionFind.unite(xVar, yVar);
            yieldRight(newUnionFind);
            unificateResult.found |= true;
          },
          (Number x) {
            if (x == y) {
              yieldRight(unionFind);
              unificateResult.found |= true;
            }
          },
          (Object _) {
          }
        );
      }
    } else if (term.token.instanceOf!ComparisonOperator) {
      // arithmetic comparison
      auto op = cast(ComparisonOperator) term.token;
      auto result = Evaluator.calc(variant.children.front, unionFind).bind!(
        x => Evaluator.calc(variant.children.back, unionFind).fmap!(
          y => op.calc(x, y)
        )
      );
      if (result.isLeft) {
        Messenger.add(result.left);
      } else {
        if (result.right) {
          yieldRight(unionFind);
          unificateResult.found |= true;
        }
      }
    } else {
      auto predResult = BuiltInPredicate.unificateTraverse(variant, unionFind, &unificate);
      if (predResult.found) {
        unificateResult = predResult;
      } else {
        foreach(clause; _storage) {
          if (unificateResult.isCutted) break;
          Variant first, second;
          UnificationUF newUnionFind = unionFind ~ buildUnionFind(clause, first, second);
          if (match(variant, first, newUnionFind)) {
            clause.castSwitch!(
              (Fact fact) {
                yieldRight(newUnionFind);
                unificateResult.found |= true;
              },
              (Rule rule) {
                auto r = unificate(second, newUnionFind);
                unificateResult.isCutted |= r.isCutted;
                unificateResult.found |= r.found;
              }
            );
          }
        }

      }
    }

    return unificateResult;
  }

  void yieldLeft() {
    static CallUnificateNotifier notifier;
    if (!notifier) {
      notifier = new CallUnificateNotifier;
    }
    Left!(CallUnificateNotifier, UnificationUF)(notifier).yield;
  }

  void yieldRight(UnificationUF uf) {
    Right!(CallUnificateNotifier, UnificationUF)(uf).yield;
  }

  bool match(Variant left, Variant right, UnificationUF unionFind) {
    if (!left.isVariable && !right.isVariable) {
      return left.term.token == right.term.token && left.children.length==right.children.length && zip(left.children, right.children).all!(a => match(a[0], a[1], unionFind));
    } else {
      Variant l = unionFind.root(left);
      Variant r = unionFind.root(right);
      if (unionFind.same(l, r)) {
        return true;
      } else if (!l.isVariable && !r.isVariable) {
        return match(l, r, unionFind);
      } else {
        unionFind.unite(l, r);
        return true;
      }
    }
  }

  UnificationUF buildUnionFind(Clause clause, ref Variant first, ref Variant second) {
    static long idGen = 0;
    static long idGen_underscore = 0;
    const long id = ++idGen;

    UnificationUF uf = new UnificationUF;

    Variant rec(Term term) {
      Variant v = new Variant(
        term.token.isUnderscore ? ++idGen_underscore :
        term.isVariable         ? id
                                : -1,
        term,
        term.children.map!(c => rec(c)).array
      );
      uf.add(v);
      return v;
    }

    clause.castSwitch!(
      (Fact fact) {
        first = rec(fact.first);
      },
      (Rule rule) {
        first = rec(rule.first);
        second = rec(rule.second);
      },
      (Query query) {
        first = rec(query.first);
      }
    );

    return uf;
  }

  invariant {
    assert(_storage.all!(clause => clause.instanceOf!Fact || clause.instanceOf!Rule));
  }

}
