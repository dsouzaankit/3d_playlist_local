# To re-calibrate relative cursor (x,y) coordinates in case screen resolution changes!

# python -m venv P:\all_scripts\py_venv1
# P:\all_scripts\py_venv1\Scripts\activate
# pip install pyautogui

import pyautogui

# Get the current X and Y coordinates of the mouse cursor
current_x, current_y = pyautogui.position()

print(f"Current cursor coordinates: X={current_x}, Y={current_y}")
