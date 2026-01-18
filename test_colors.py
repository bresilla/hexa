#!/usr/bin/env python3
"""Simple color test - no cursor movement."""
import sys

print("=" * 50)
print("BASIC COLORS TEST")
print("=" * 50)

# Basic 8 colors
print("\n--- Basic Foreground (30-37) ---")
for i in range(30, 38):
    print(f"\033[{i}m Color {i} \033[0m", end=" ")
print()

print("\n--- Basic Background (40-47) ---")
for i in range(40, 48):
    print(f"\033[{i}m Color {i} \033[0m", end=" ")
print()

# 256 colors - THIS IS LIKELY THE PROBLEM AREA
print("\n--- 256 Foreground (38;5;N) ---")
for i in range(0, 16):
    print(f"\033[38;5;{i}m#{i:02d}\033[0m", end=" ")
print()

print("\n--- 256 Background (48;5;N) ---")
for i in range(0, 16):
    print(f"\033[48;5;{i}m {i:02d} \033[0m", end=" ")
print()

# RGB - ANOTHER LIKELY PROBLEM AREA
print("\n--- RGB Foreground (38;2;R;G;B) ---")
print(f"\033[38;2;255;0;0mRED\033[0m ", end="")
print(f"\033[38;2;0;255;0mGREEN\033[0m ", end="")
print(f"\033[38;2;0;0;255mBLUE\033[0m")

print("\n--- RGB Background (48;2;R;G;B) ---")
print(f"\033[48;2;255;0;0m RED \033[0m ", end="")
print(f"\033[48;2;0;255;0m GRN \033[0m ", end="")
print(f"\033[48;2;0;0;255m BLU \033[0m")

# Attributes
print("\n--- Text Attributes ---")
print(f"\033[1mBold\033[0m ", end="")
print(f"\033[3mItalic\033[0m ", end="")
print(f"\033[4mUnderline\033[0m ", end="")
print(f"\033[7mInverse\033[0m ", end="")
print(f"\033[9mStrike\033[0m")

# Combined
print("\n--- Combined ---")
print(f"\033[1;31mBold Red\033[0m ", end="")
print(f"\033[1;38;5;208mBold Orange 256\033[0m ", end="")
print(f"\033[1;38;2;255;0;255mBold Magenta RGB\033[0m")

print("\n" + "=" * 50)
print("TEST DONE - Check above for garbled text")
print("=" * 50)
