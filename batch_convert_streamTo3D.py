# python -m venv P:\all_scripts\py_venv1
# P:\all_scripts\py_venv1\Scripts\activate
# pip install pywinauto

from pywinauto import Application
from pywinauto import keyboard
import time
from pathlib import Path
import sys


# 1. Start an application (or connect to an existing one)
app = Application().start(r'C:\Program Files\StreamTo3D\Streamto3D.exe')
# app = Application().connect(path=r'C:\Program Files\StreamTo3D\Streamto3D.exe')
time.sleep(4)
# Select the main window (dialog)
main_dlg = app.top_window()

# used to compute final sleep delay before closing streamTo3D window!
def count_video_files(directory_path):
    """
    Counts the number of video files in a given directory (non-recursive).
    """
    # A set of common video file extensions (case-insensitive check is done later).
    video_extensions = {'.mp4', '.mov', '.avi', '.mkv', '.wmv', '.ts'}
    path = Path(directory_path)
    if not path.is_dir():
        return f"Error: The path '{directory_path}' is not a valid directory."
    count = 0
    # Iterate over all items in the directory
    for file_path in path.iterdir():
        if file_path.is_file() and file_path.suffix.lower() in video_extensions:
            count += 1
    return count

try:
    # Bring window to foreground first for click_input reliability
    main_dlg.set_focus()
    # 2. Send a click event at specific coordinates (e.g., x=100, y=100)
    # The coordinates (100, 100) are relative to the top-left of the main_dlg window.
    # Use click_input() for a "realistic" physical mouse click that requires the window to be visible.
    main_dlg.click_input(coords=(1541, 657))
    print(f"Clicked Convert")
    main_dlg.click_input(coords=(1319, 231))
    print(f"Clicked top url bar")
    base_path_obj = Path(__file__).parent
    media_files_path = base_path_obj.parent
    op_path = f"{base_path_obj}\\op_logs"
    # print(f"script at: {script_path}")
    print(f"media_files.txt at: {media_files_path}")
    print(f"o/p folder (dummy) at: {op_path}")
    keyboard.send_keys(str(media_files_path), with_spaces=True)
    keyboard.send_keys("{ENTER}")
    main_dlg.click_input(coords=(1510, 923))
    print(f"Clicked 'Videos 1' (i/p filter)")
    main_dlg.click_input(coords=(1510, 645))
    print(f"Selected 'All Files' (i/p filter)")
    main_dlg.click_input(coords=(1342, 915))
    print(f"Focused on Filename bar")
    keyboard.send_keys('media_files.txt')
    keyboard.send_keys("{ENTER}")
    main_dlg.click_input(coords=(1319, 231))
    print(f"Clicked Top Path bar (folder paths)")
    keyboard.send_keys(op_path, with_spaces=True)
    main_dlg.click_input(coords=(1319, 990))
    print(f"Clicked Select (final)")

except Exception as e:
    print(f"An error occurred during click: {e}")

video_count = count_video_files(str(base_path_obj.parent))
# assume below constant time needed per video avs file
avs_wait_time = 7 * video_count
print(f'Waiting {avs_wait_time}s for conversion!')
time.sleep(avs_wait_time)
main_dlg.close()
