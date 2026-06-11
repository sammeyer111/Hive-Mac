import os
from PIL import Image

def process_image(src_path, recenter_path, final_path, zoom_size=70, final_size=90):
    img = Image.open(src_path).convert("RGBA")
    
    # 1. Recenter original
    bbox = img.getbbox()
    if not bbox:
        # Empty image, just copy
        img.save(recenter_path)
        img.save(final_path)
        return

    # Extract content
    content = img.crop(bbox)
    content_w, content_h = content.size
    
    # Create new 90x90 and center content
    centered = Image.new("RGBA", (final_size, final_size), (0, 0, 0, 0))
    offset = ((final_size - content_w) // 2, (final_size - content_h) // 2)
    centered.paste(content, offset)
    centered.save(recenter_path)
    
    # 2. Zoom (Crop center and Resample)
    left = (final_size - zoom_size) / 2
    top = (final_size - zoom_size) / 2
    right = (final_size + zoom_size) / 2
    bottom = (final_size + zoom_size) / 2
    
    zoomed = centered.crop((left, top, right, bottom))
    final = zoomed.resize((final_size, final_size), Image.Resampling.LANCZOS)
    final.save(final_path)

for folder in ['carbon', 'classic']:
    for filename in os.listdir(folder):
        if filename.endswith("-old.png"):
            src = os.path.join(folder, filename)
            base = filename.replace("-old.png", "")
            recenter = os.path.join(folder, f"{base}-recentered.png")
            final = os.path.join(folder, f"{base}.png")
            
            print(f"Processing: {base}")
            process_image(src, recenter, final)
