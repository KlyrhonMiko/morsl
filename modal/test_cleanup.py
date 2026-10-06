"""Regression coverage for optimized dish completion."""
import unittest
from unittest.mock import patch

import numpy as np
from PIL import Image, ImageDraw

from image_contract import dish_silhouette, prepare_dish_candidates


def legacy_fill(mask):
    padded = Image.fromarray(np.pad(mask.astype(np.uint8) * 255, 1)).copy()
    ImageDraw.floodfill(padded, (0, 0), 128)
    return np.asarray(padded)[1:-1, 1:-1] != 128


class CleanupTests(unittest.TestCase):
    def test_fill_matches_previous_connectivity_on_random_and_thin_masks(self):
        rng = np.random.default_rng(20261006)
        masks = [rng.random((37, 53)) < density
                 for density in (.05, .3, .5, .8, .95) for _ in range(10)]
        # An enclosed hole with only a diagonal connection to the exterior
        # stays filled with four-neighbour connectivity.
        diagonal = np.ones((9, 9), bool)
        np.fill_diagonal(diagonal, False)
        masks.extend([diagonal, np.eye(9, dtype=bool),
                      np.ones((1, 17), bool), np.ones((17, 1), bool)])
        for index, mask in enumerate(masks):
            with self.subTest(index=index):
                actual = dish_silhouette(mask)
                with patch("image_contract.binary_fill_holes", legacy_fill):
                    expected = dish_silhouette(mask)
                np.testing.assert_array_equal(actual, expected)

    def test_full_resolution_hole_and_clipped_rim(self):
        y, x = np.ogrid[:1200, :1600]
        for center in (800, 50):
            outer = ((x - center) / 600) ** 2 + ((y - 600) / 450) ** 2 <= 1
            inner = ((x - center) / 590) ** 2 + ((y - 600) / 440) ** 2 < 1
            result = dish_silhouette(outer & ~inner)
            self.assertTrue(result[600, center])
            self.assertTrue(np.all(result[outer & ~inner]))
            self.assertFalse(result[0, 1599])
            if center == 800:
                np.testing.assert_array_equal(result, outer)

    def test_empty_low_confidence_and_tiny_masks_are_rejected(self):
        empty = np.zeros((100, 100), bool)
        tiny = empty.copy()
        tiny[10:12, 10:12] = True
        np.testing.assert_array_equal(dish_silhouette(empty), empty)
        self.assertEqual(prepare_dish_candidates(
            [(empty, .9), (tiny, .9), (np.ones_like(empty), .4)], 100, 100,
        ), [])
        for mask, score in [(np.zeros((99, 100)), .9), (empty, float("nan"))]:
            with self.assertRaises(ValueError):
                prepare_dish_candidates([(mask, score)], 100, 100)


if __name__ == "__main__":
    unittest.main()
