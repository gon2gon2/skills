import ast
import io
import json
import sys
import tokenize


def scan(paths):
    result = {}
    for path in paths:
        with open(path, encoding="utf8") as handle:
            text = handle.read()
        found = []
        for token in tokenize.generate_tokens(io.StringIO(text).readline):
            if token.type == tokenize.COMMENT:
                found.append({"line": token.start[0], "col": token.start[1], "text": token.string})
        result[path] = found
    return result


def same_ast(before, after):
    with open(before, encoding="utf8") as handle:
        left = ast.dump(ast.parse(handle.read()))
    with open(after, encoding="utf8") as handle:
        right = ast.dump(ast.parse(handle.read()))
    return left == right


def main():
    command = sys.argv[1]
    if command == "scan":
        paths = [line for line in sys.stdin.read().split("\n") if line]
        json.dump(scan(paths), sys.stdout)
        return 0
    if command == "same-ast":
        return 0 if same_ast(sys.argv[2], sys.argv[3]) else 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
