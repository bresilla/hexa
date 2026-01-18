#!/usr/bin/env python3
"""Test what escape sequences your terminal sends for various keys."""
import sys
import tty
import termios

def main():
    print("Press keys to see their escape sequences. Ctrl+C to exit.")
    print("-" * 50)
    
    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    
    try:
        tty.setraw(fd)
        while True:
            ch = sys.stdin.read(1)
            if ch == '\x03':  # Ctrl+C
                break
            
            # Read any additional bytes (for escape sequences)
            import select
            chars = [ch]
            while select.select([sys.stdin], [], [], 0.01)[0]:
                chars.append(sys.stdin.read(1))
            
            # Print the sequence
            seq = ''.join(chars)
            hex_repr = ' '.join(f'{ord(c):02x}' for c in seq)
            escaped = seq.replace('\x1b', 'ESC')
            
            # Reset terminal temporarily to print
            termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
            print(f"Bytes: {hex_repr}")
            print(f"Repr:  {repr(seq)}")
            print(f"Visual: {escaped}")
            print("-" * 30)
            tty.setraw(fd)
            
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
        print("\nDone!")

if __name__ == "__main__":
    main()
