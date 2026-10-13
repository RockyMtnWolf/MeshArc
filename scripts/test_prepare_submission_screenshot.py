import importlib.util
import tempfile
import unittest
from pathlib import Path

from PIL import Image


SCRIPT_PATH = Path(__file__).with_name('prepare-submission-screenshot.py')
MODULE_SPEC = importlib.util.spec_from_file_location('prepare_submission_screenshot', SCRIPT_PATH)
SCREENSHOT_MODULE = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(SCREENSHOT_MODULE)


class PrepareSubmissionScreenshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.directory = Path(self.temporary_directory.name)
        self.source = self.directory / 'synthetic.png'
        self.destination = self.directory / 'prepared.png'
        Image.new('RGB', (2600, 1500), (20, 80, 140)).save(self.source)

    def test_crop_produces_1920_by_1080_png(self):
        SCREENSHOT_MODULE.prepare_screenshot(
            self.source, self.destination, (20, 10, 2580, 1450)
        )

        with Image.open(self.destination) as prepared:
            self.assertEqual(prepared.size, (1920, 1080))
            self.assertEqual(prepared.format, 'PNG')
            self.assertEqual(prepared.mode, 'RGB')

    def test_rejects_bounds_outside_source_image(self):
        invalid_bounds = (
            (-1, 0, 2559, 1440),
            (0, 0, 2560, 1501),
            (10, 0, 10, 100),
            (0, 20, 100, 20),
        )
        for bounds in invalid_bounds:
            with self.subTest(bounds=bounds):
                with self.assertRaisesRegex(ValueError, 'within the original screenshot'):
                    SCREENSHOT_MODULE.prepare_screenshot(self.source, self.destination, bounds)
                self.assertFalse(self.destination.exists())

    def test_rejects_non_16_by_9_crop(self):
        with self.assertRaisesRegex(ValueError, '16:9'):
            SCREENSHOT_MODULE.prepare_screenshot(
                self.source, self.destination, (0, 0, 1920, 1440)
            )

    def test_rejects_16_by_9_crop_below_minimum_resolution(self):
        with self.assertRaisesRegex(ValueError, 'at least 1920x1080'):
            SCREENSHOT_MODULE.prepare_screenshot(
                self.source, self.destination, (0, 0, 1280, 720)
            )


if __name__ == '__main__':
    unittest.main()
