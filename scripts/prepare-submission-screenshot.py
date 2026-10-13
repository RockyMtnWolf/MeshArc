import argparse
from pathlib import Path

from PIL import Image


def prepare_screenshot(source, destination, bounds):
    with Image.open(source) as screenshot:
        left, top, right, bottom = bounds
        if not (0 <= left < right <= screenshot.width and 0 <= top < bottom <= screenshot.height):
            raise ValueError('Application bounds must stay within the original screenshot')
        application = screenshot.crop(bounds).convert('RGB')
        if application.width * 9 != application.height * 16:
            raise ValueError('Capture an application window with a 16:9 content area')
        if application.width < 1920 or application.height < 1080:
            raise ValueError('Application capture must be at least 1920x1080')
        application.resize((1920, 1080), Image.Resampling.LANCZOS).save(destination, format='PNG')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--bounds', type=int, nargs=4, required=True)
    arguments = parser.parse_args()
    prepare_screenshot(arguments.source, arguments.destination, tuple(arguments.bounds))


if __name__ == '__main__':
    main()
