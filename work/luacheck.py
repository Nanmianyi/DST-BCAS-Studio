import sys

def balance(path):
    s = open(path, encoding='utf-8').read()
    i = 0
    n = len(s)
    st = []
    pairs = {')': '(', '}': '{', ']': '['}
    while i < n:
        c = s[i]
        if c == '-' and i + 1 < n and s[i + 1] == '-':
            if s[i + 2:i + 4] == '[[':
                j = s.find(']]', i + 4)
                i = (j + 2) if j >= 0 else n
                continue
            j = s.find('\n', i)
            i = (j if j >= 0 else n)
            continue
        if c == '[' and s[i + 1:i + 2] == '[':
            j = s.find(']]', i + 2)
            i = (j + 2) if j >= 0 else n
            continue
        if c == '"' or c == "'":
            q = c
            i += 1
            while i < n and s[i] != q:
                if s[i] == '\\':
                    i += 2
                else:
                    i += 1
            i += 1
            continue
        if c in '({[':
            st.append(c); i += 1; continue
        if c in ')}]':
            if not st or st[-1] != pairs[c]:
                return 'BAD at %d char %s' % (i, c)
            st.pop(); i += 1; continue
        i += 1
    return 'OK' if not st else 'UNCLOSED %s' % st[:8]

for f in sys.argv[1:]:
    print(balance(f), f)
