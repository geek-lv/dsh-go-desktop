// 纯 unified diff 解析：只认 `---` / `+++` / `@@` 与 ` `、`-`、`+`、`\` 四种行。
//
// 这是 `runtime/lib/rtbuild.py: parse_unified_diff` 的逐条移植（同样的校验、同样的
// 行数语义），因为补丁链的可信度就建立在这些规则上：不 fuzz、不做模糊匹配，
// 上游文件一变就必须重新审查补丁，而不是"尽量对上"。

/** 按 \n 切分并保留行尾（等价 Python 的 splitlines(keepends=True)）。 */
export function splitKeepingEnds(text) {
  const out = [];
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    if (text.charCodeAt(i) === 0x0a) {
      out.push(text.slice(start, i + 1));
      start = i + 1;
    }
  }
  if (start < text.length) out.push(text.slice(start));
  return out;
}

/**
 * @returns {Array<{path: string, hunks: Array<{oldText: string, newText: string}>}>}
 */
export function parseUnifiedDiff(text) {
  const lines = splitKeepingEnds(text);
  const files = [];
  let cur = null;
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (line.startsWith('--- ')) {
      const plus = i + 1 < lines.length ? lines[i + 1] : '';
      if (!plus.startsWith('+++ ')) throw new Error(`第 ${i + 1} 行：--- 后面没有 +++`);
      let path = plus.slice(4).split('\t')[0].trim();
      if (path.startsWith('b/')) path = path.slice(2);
      if (path.startsWith('/') || path.split('/').includes('..')) {
        throw new Error(`diff 里有不安全的路径：${path}`);
      }
      cur = { path, hunks: [] };
      files.push(cur);
      i += 2;
      continue;
    }
    if (line.startsWith('@@')) {
      if (cur === null) throw new Error(`第 ${i + 1} 行：hunk 出现在文件头之前`);
      // "@@ -a,b +c,d @@" → 取 b、d（没有逗号时为 1）
      const head = line.split('@@')[1].split(/\s+/).filter(Boolean);
      const counts = [];
      for (const token of head) {
        if (!token.startsWith('-') && !token.startsWith('+')) continue;
        counts.push(token.includes(',') ? Number(token.split(',')[1]) : 1);
      }
      if (counts.length < 2) throw new Error(`第 ${i + 1} 行：hunk 头无法解析：${line}`);
      let leftOld = counts[0];
      let leftNew = counts[1];
      const oldParts = [];
      const newParts = [];
      i += 1;
      while (leftOld > 0 || leftNew > 0) {
        if (i >= lines.length) throw new Error(`hunk 被截断：${cur.path}`);
        const body = lines[i];
        i += 1;
        if (body.startsWith('\\')) continue; // "\ No newline at end of file"
        let tag = body === '' ? '' : body[0];
        let rest = body === '' ? '' : body.slice(1);
        if (body === '\n' || body === '\r\n') {
          // 前导空格被剥掉的上下文行
          tag = ' ';
          rest = body;
        }
        if (tag === ' ') {
          oldParts.push(rest);
          newParts.push(rest);
          leftOld -= 1;
          leftNew -= 1;
        } else if (tag === '-') {
          oldParts.push(rest);
          leftOld -= 1;
        } else if (tag === '+') {
          newParts.push(rest);
          leftNew -= 1;
        } else {
          const shown = body.length > 40 ? body.slice(0, 40) : body;
          throw new Error(`第 ${i} 行：hunk 行无法识别：${JSON.stringify(shown)}`);
        }
      }
      if (leftOld !== 0 || leftNew !== 0) {
        throw new Error(`hunk 行数与头部不一致：${cur.path}`);
      }
      cur.hunks.push({ oldText: oldParts.join(''), newText: newParts.join('') });
      continue;
    }
    i += 1;
  }
  return files;
}

/** 非重叠出现次数（相当于 Python 的 str.count）。 */
export function countOccurrences(haystack, needle) {
  if (needle === '') return 0;
  let count = 0;
  let at = haystack.indexOf(needle);
  while (at >= 0) {
    count += 1;
    at = haystack.indexOf(needle, at + needle.length);
  }
  return count;
}

/**
 * 每个 hunk 的「原文块」必须恰好出现一次；不 fuzz，任何偏移都不接受。
 * 与 `rtbuild.py: apply_hunks` 完全一致。
 */
export function applyHunks(data, hunks, label) {
  let out = data;
  for (let i = 0; i < hunks.length; i++) {
    const { oldText, newText } = hunks[i];
    const count = countOccurrences(out, oldText);
    if (count !== 1) {
      throw new PatchContextError(
        `${label}: hunk ${i + 1} 命中 ${count} 处（需要恰好 1 处）；上游文件变了，需要重新审查补丁`,
        count > 1,
      );
    }
    const at = out.indexOf(oldText);
    out = out.slice(0, at) + newText + out.slice(at + oldText.length);
  }
  return out;
}

export class PatchContextError extends Error {
  constructor(message, ambiguous) {
    super(message);
    this.name = 'PatchContextError';
    this.ambiguous = ambiguous;
  }
}
