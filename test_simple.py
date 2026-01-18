#!/usr/bin/env python3
"""Simple test without cursor movement."""

print("=" * 50)
print("SIMPLE COLORS TEST - NO CURSOR MOVEMENT")
print("=" * 50)

# Basic colors
print("\n--- Foreground Colors ---")
for i in range(8):
    print(f"\033[3{i}m Color {i} \033[0m", end="")
print()

# 256 colors  
print("\n--- 256 Colors ---")
for i in range(16):
    print(f"\033[38;5;{i}m#{i:02d}\033[0m", end=" ")
print()

# RGB
print("\n--- RGB Colors ---")
print(f"\033[38;2;255;0;0mRED\033[0m ", end="")
print(f"\033[38;2;0;255;0mGREEN\033[0m ", end="")
print(f"\033[38;2;0;0;255mBLUE\033[0m")

# Styles
print("\n--- Styles ---")
print(f"\033[1mBold\033[0m ", end="")
print(f"\033[3mItalic\033[0m ", end="")
print(f"\033[4mUnderline\033[0m")

# Multiple lines
print("\n--- Multi-line ---")
for i in range(20):
    print(f"Line {i+1}: The quick brown fox jumps over the lazy dog")

print("\n" + "=" * 50)
print("TEST COMPLETE - scroll up to see earlier output")
print("=" * 50)
print("\nPress Enter to exit...")
input()
