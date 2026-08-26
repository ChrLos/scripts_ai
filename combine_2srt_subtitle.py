import os
import sys
from typing import List, Dict, Optional, Tuple

# ---------- SRT Parsing ----------

def parse_srt(filepath: str) -> List[Dict]:
    """
    Parse a standard .srt file into a list of cue dictionaries.
    Each cue contains: index (original), start, end, text.
    """
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read().strip()
    except FileNotFoundError:
        print(f"❌ File not found: {filepath}")
        sys.exit(1)

    blocks = content.split('\n\n')
    cues = []
    for block in blocks:
        lines = block.split('\n')
        if len(lines) >= 2:
            try:
                index = int(lines[0].strip())
                start, end = lines[1].split(' --> ')
                text = '\n'.join(lines[2:]).strip()
                cues.append({
                    'index': index,
                    'start': start.strip(),
                    'end': end.strip(),
                    'text': text
                })
            except (ValueError, IndexError):
                continue  # skip malformed blocks

    return cues


def timestamp_to_seconds(ts: str) -> float:
    """Convert 'HH:MM:SS,mmm' to seconds (float)."""
    h, m, rest = ts.split(':')
    s, ms = rest.split(',')
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000.0


# ---------- Alignment ----------

def align_cues(cues1: List[Dict], cues2: List[Dict], tolerance: float = 0.5) -> List[Tuple[Optional[Dict], Optional[Dict]]]:
    """
    Align cues from two files by start time.
    Returns a list of (cue1, cue2) pairs, where either may be None if no match found.
    """
    pairs = []
    used2 = set()

    # Match each cue in file1 to best matching unused cue in file2
    for c1 in cues1:
        t1 = timestamp_to_seconds(c1['start'])
        best_idx = None
        best_diff = tolerance
        for i, c2 in enumerate(cues2):
            if i in used2:
                continue
            t2 = timestamp_to_seconds(c2['start'])
            diff = abs(t1 - t2)
            if diff <= best_diff:
                best_diff = diff
                best_idx = i

        if best_idx is not None:
            pairs.append((c1, cues2[best_idx]))
            used2.add(best_idx)
        else:
            pairs.append((c1, None))

    # Add any remaining cues from file2 that were not matched
    for i, c2 in enumerate(cues2):
        if i not in used2:
            pairs.append((None, c2))

    # Sort pairs by start time (if both are None can't happen)
    pairs.sort(key=lambda p: timestamp_to_seconds(p[0]['start'] if p[0] else p[1]['start']))
    return pairs


# ---------- Combining ----------

def combine_cues(cues1: List[Dict], cues2: List[Dict]) -> List[Dict]:
    """Merge two lists of cues into a single SRT-compatible list."""
    if len(cues1) == len(cues2):
        combined = []
        for i, (c1, c2) in enumerate(zip(cues1, cues2), 1):
            combined.append({
                'index': i,
                'start': c1['start'],
                'end': c1['end'],
                'text': c1['text'] + '\n' + c2['text']
            })
        return combined
    else:
        print("⚠️  Cue counts differ, aligning by start time (tolerance 0.5s)...")
        pairs = align_cues(cues1, cues2)
        combined = []
        for i, (c1, c2) in enumerate(pairs, 1):
            start = c1['start'] if c1 else c2['start']
            end = c1['end'] if c1 else c2['end']

            text1 = c1['text'] if c1 else ''
            text2 = c2['text'] if c2 else ''

            # Ensure two lines: language1 then language2, blank if missing
            if text1 and text2:
                merged_text = f"{text1}\n{text2}"
            elif text1:
                merged_text = f"{text1}\n"
            elif text2:
                merged_text = f"\n{text2}"
            else:
                merged_text = "\n"  # shouldn't happen

            combined.append({
                'index': i,
                'start': start,
                'end': end,
                'text': merged_text
            })
        return combined


# ---------- Writing SRT ----------

def write_srt(filepath: str, cues: List[Dict]) -> None:
    """Write cue list to an SRT file."""
    with open(filepath, 'w', encoding='utf-8') as f:
        for cue in cues:
            f.write(f"{cue['index']}\n")
            f.write(f"{cue['start']} --> {cue['end']}\n")
            f.write(f"{cue['text']}\n\n")


# ---------- Main ----------

def main():
    print("=== SRT Language Combiner ===")
    print("Combine two subtitle files (different languages) into one bilingual SRT.\n")

    file1 = input("Enter the first .srt file (language 1): ").strip()
    file2 = input("Enter the second .srt file (language 2): ").strip()

    if not os.path.isfile(file1):
        print(f"❌ File not found: {file1}")
        return
    if not os.path.isfile(file2):
        print(f"❌ File not found: {file2}")
        return

    print("\nParsing subtitles...")
    cues1 = parse_srt(file1)
    cues2 = parse_srt(file2)
    print(f"   {file1}: {len(cues1)} cues")
    print(f"   {file2}: {len(cues2)} cues")

    if not cues1 or not cues2:
        print("❌ No valid cues found in one or both files.")
        return

    print("\nCombining...")
    merged = combine_cues(cues1, cues2)

    out_file = input("\nOutput file name (default: combined.srt): ").strip()
    if not out_file:
        out_file = "combined.srt"
    if not out_file.endswith('.srt'):
        out_file += '.srt'

    write_srt(out_file, merged)
    print(f"\n✅ Successfully created {out_file} with {len(merged)} cues.")
    print("Each subtitle now contains two lines: first language, then second language.")


if __name__ == "__main__":
    main()