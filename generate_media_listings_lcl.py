import os


def list_media_and_save_in_subdirectories(root_directory):
    """
    Lists all media files in a given root directory and its subdirectories,
    saving the list to a 'media_files.txt' file in each subdirectory.
    Order: modification time ascending (oldest first), using the original
    file under dirpath for the timestamp (standardized path may still be written).
    """
    for dirpath, dirnames, filenames in os.walk(root_directory):
        media_entries = []
        for filename in filenames:
            # AppleDouble sidecars (._name.ext): macOS metadata on SMB/exFAT; not real media, often Hidden in Explorer.
            if filename.startswith("._"):
                continue
            if filename.lower().endswith((".mp4", ".wmv", ".ts", ".mkv")):
                original_path = os.path.join(dirpath, filename)
                stdzd_filename = os.path.join(os.getcwd(), 'standardized', filename)
                if os.path.isfile(stdzd_filename):
                    print(f"Standardized variant found ({stdzd_filename}). Prioritizing over its original!")
                    write_path = stdzd_filename
                else:
                    write_path = original_path
                try:
                    mtime = os.path.getmtime(original_path)
                except OSError:
                    mtime = 0.0
                media_entries.append((mtime, write_path))

        if media_entries:  # Only create file if media is found
            media_entries.sort(key=lambda entry: entry[0])
            output_file_path = os.path.join(dirpath, "media_files.txt")
            with open(output_file_path, "w", encoding='utf-8') as f:
                for _, write_path in media_entries:
                    f.write(write_path + "\n")
            print(f"Media files listed and saved in: {output_file_path}")

if __name__ == '__main__':
    # root_dirs = ['F:\\f1_media', 'E:\\e1_media', 'D:\\d1_media', 'P:\\combo_media_dlna']
    # root_dirs = ['F:\\f1_media\\di_media_1']
    root_dirs = [os.path.dirname(os.getcwd())]
    print(f"Root dirs: {root_dirs}")
    for root_dir in root_dirs:
        # Replace 'your_root_directory_path' with the actual path you want to scan
        list_media_and_save_in_subdirectories(root_dir)
