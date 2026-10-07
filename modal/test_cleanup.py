"""Regression coverage for optimized dish completion."""
import unittest
from unittest.mock import patch

import numpy as np
from PIL import Image, ImageDraw

from image_contract import (dish_silhouette, prepare_dish_candidates, encode_plates,
                            group_serving_boards, prepare_serving_boards)


def legacy_fill(mask):
    padded = Image.fromarray(np.pad(mask.astype(np.uint8) * 255, 1)).copy()
    ImageDraw.floodfill(padded, (0, 0), 128)
    return np.asarray(padded)[1:-1, 1:-1] != 128


class CleanupTests(unittest.TestCase):
    def test_small_food_filled_corner_bowl_is_omitted_beside_main_plate(self):
        main, salad = np.zeros((200, 150), bool), np.zeros((200, 150), bool)
        main[30:185, 15:110] = True
        salad[0:45, 120:150] = True
        main_food, salad_food = np.zeros_like(main), np.zeros_like(main)
        main_food[70:140, 35:90] = True
        salad_food[5:35, 125:145] = True
        dishes = prepare_dish_candidates([(main, .9), (salad, .99)], 150, 200,
                                         food_candidates=[(main_food, .9), (salad_food, .9)])
        # Both are real food-bearing dishes; composition filtering drops the side.
        self.assertEqual(len(dishes), 2)
        result = encode_plates(dishes, 150, 200)
        self.assertEqual(len(result["plates"]), 1)
        self.assertEqual(result["plates"][0]["bounds"], [.1, .15, 95 / 150, .775])

    def test_corner_rule_preserves_full_side_bowl_and_single_edge_bowl(self):
        main = np.zeros((200, 150), bool)
        main[30:185, 15:110] = True
        for top, left in [(5, 115), (0, 115), (60, 125)]:
            side = np.zeros_like(main)
            side[top:top + 25, left:left + 25] = True
            result = encode_plates([(main, .9), (side, .99)], 150, 200)
            self.assertEqual(len(result["plates"]), 2)

    def test_main_corner_clipped_dish_survives_without_larger_subject(self):
        dish = np.zeros((200, 150), bool)
        dish[0:45, 120:150] = True
        self.assertEqual(len(encode_plates([(dish, .9)], 150, 200)["plates"]), 1)

    def test_large_corner_clipped_meal_is_preserved(self):
        main, side = np.zeros((200, 150), bool), np.zeros((200, 150), bool)
        main[50:190, 5:80] = True
        side[0:70, 85:150] = True
        self.assertEqual(len(encode_plates([(main, .9), (side, .99)], 150, 200)["plates"]), 2)

    def test_near_border_mask_jitter_still_filters_incidental_corner_bowl(self):
        main, side = np.zeros((200, 150), bool), np.zeros((200, 150), bool)
        main[30:185, 15:110] = True
        side[1:40, 120:149] = True
        self.assertEqual(len(encode_plates([(main, .9), (side, .99)], 150, 200)["plates"]), 1)

    def test_table_with_food_in_bowls_is_not_prioritized_as_a_board(self):
        table = np.ones((200, 200), bool)
        bowl, food = np.zeros_like(table), np.zeros_like(table)
        bowl[40:160, 40:160] = True
        food[60:140, 60:140] = True
        boards = prepare_serving_boards([(table, .99)], 200, 200,
                                       [(food, .9)], [(bowl, .9)])
        self.assertEqual(boards, [])
        result = group_serving_boards([(bowl, .9)], boards, [])
        np.testing.assert_array_equal(result[0][0], bowl)

    def test_board_with_direct_meat_and_bowls_is_eligible_for_grouping(self):
        board = np.zeros((200, 200), bool)
        board[30:180, 20:180] = True
        bowl, meat, rice = (np.zeros_like(board) for _ in range(3))
        bowl[110:190, 100:170] = True
        meat[85:125, 50:100] = True
        rice[125:170, 115:155] = True
        boards = prepare_serving_boards([(board, .9)], 200, 200,
                                       [(meat, .9), (rice, .9)], [(bowl, .9)])
        self.assertEqual(len(boards), 1)
        np.testing.assert_array_equal(boards[0][0], board)

    def test_small_food_spill_outside_bowl_does_not_promote_table(self):
        table = np.ones((100, 100), bool)
        bowl, food = np.zeros_like(table), np.zeros_like(table)
        bowl[20:80, 20:80] = True
        food[30:70, 30:85] = True
        self.assertEqual(prepare_serving_boards([(table, .99)], 100, 100,
                         [(food, .9)], [(bowl, .9)]), [])

    def test_board_groups_bowls_meat_and_protruding_condiment_bowl(self):
        board = np.zeros((200, 200), bool)
        board[30:180, 20:180] = True
        rice, pickles, sauce, meat, nearby = (np.zeros_like(board) for _ in range(5))
        rice[110:190, 100:170] = True
        pickles[40:80, 30:70] = True
        sauce[20:60, 90:130] = True
        meat[85:125, 50:100] = True
        nearby[5:25, 175:195] = True
        result = group_serving_boards(
            [(rice, .99), (pickles, .95), (nearby, .9)], [(board, .8)],
            [(rice, .99), (pickles, .95), (sauce, .9), (meat, .9)],
        )
        self.assertEqual(len(result), 2)
        np.testing.assert_array_equal(result[0][0], board | rice | sauce)
        np.testing.assert_array_equal(result[1][0], nearby)
        # The table outside the combined outline is still transparent.
        self.assertFalse(result[0][0][20, 30])
        self.assertEqual(len(encode_plates(result, 200, 200)["plates"]), 2)

    def test_board_association_does_not_chain_to_neighboring_bowl(self):
        board = np.zeros((100, 200), bool)
        board[10:90, 10:100] = True
        on_board, neighbor = np.zeros_like(board), np.zeros_like(board)
        on_board[30:70, 70:120] = True
        neighbor[30:70, 95:135] = True
        result = group_serving_boards(
            [(on_board, .9), (neighbor, .9)], [(board, .8)],
            [(on_board, .9), (neighbor, .9)],
        )
        self.assertEqual(len(result), 2)
        self.assertFalse(result[0][0][40, 130])

    def test_two_boards_stay_separate_and_duplicate_board_is_removed(self):
        a, b = np.zeros((100, 200), bool), np.zeros((100, 200), bool)
        a[10:90, 10:90] = True
        b[10:90, 110:190] = True
        result = group_serving_boards([], [(a, .9), (a.copy(), .85), (b, .8)], [])
        self.assertEqual(len(result), 2)

    def test_empty_board_fails_food_filter_and_dishes_stay_separate(self):
        board = np.ones((100, 100), bool)
        boards = prepare_dish_candidates([(board, .9)], 100, 100, food_candidates=[])
        dish = np.zeros_like(board)
        dish[20:80, 20:80] = True
        result = group_serving_boards([(dish, .9)], boards, [])
        self.assertEqual(len(result), 1)
        np.testing.assert_array_equal(result[0][0], dish)

    def test_only_food_containing_dish_survives_empty_plate_and_table_edge(self):
        dish = np.zeros((200, 200), bool)
        dish[60:150, 60:160] = True
        empty_plate = np.zeros_like(dish)
        empty_plate[5:50, 5:60] = True
        table_edge = np.zeros_like(dish)
        table_edge[180:200, 20:180] = True
        food = np.zeros_like(dish)
        food[90:120, 90:130] = True
        result = prepare_dish_candidates(
            [(dish, .8), (empty_plate, .99), (table_edge, .95)], 200, 200,
            food_candidates=[(food, .9)],
        )
        self.assertEqual(len(result), 1)
        np.testing.assert_array_equal(result[0][0], dish)

    def test_empty_food_results_do_not_restore_empty_dishes(self):
        dish = np.ones((100, 100), bool)
        self.assertEqual(prepare_dish_candidates(
            [(dish, .99)], 100, 100, food_candidates=[],
        ), [])
        self.assertEqual(prepare_dish_candidates(
            [(dish, .99)], 100, 100, food_candidates=[(dish, .49)],
        ), [])

    def test_food_in_rim_hole_preserves_entire_dessert_plate(self):
        y, x = np.ogrid[:100, :120]
        outer = ((x - 60) / 45) ** 2 + ((y - 50) / 35) ** 2 <= 1
        inner = ((x - 60) / 38) ** 2 + ((y - 50) / 28) ** 2 < 1
        food = ((x - 60) / 15) ** 2 + ((y - 50) / 15) ** 2 <= 1
        result = prepare_dish_candidates(
            [(outer & ~inner, .9)], 120, 100, food_candidates=[(food, .9)],
        )
        self.assertEqual(len(result), 1)
        np.testing.assert_array_equal(result[0][0], outer)

    def test_clipped_food_filled_dish_survives_but_empty_partial_plate_does_not(self):
        y, x = np.ogrid[:100, :200]
        outer = ((x - 5) / 60) ** 2 + ((y - 50) / 40) ** 2 <= 1
        inner = ((x - 5) / 54) ** 2 + ((y - 50) / 34) ** 2 < 1
        empty_partial = ((x - 195) / 40) ** 2 + ((y - 50) / 40) ** 2 <= 1
        food = ((x - 10) / 20) ** 2 + ((y - 50) / 20) ** 2 <= 1
        result = prepare_dish_candidates(
            [(outer & ~inner, .85), (empty_partial, .95)], 200, 100,
            food_candidates=[(food, .9)],
        )
        self.assertEqual(len(result), 1)
        self.assertTrue(result[0][0][50, 0])
        self.assertFalse(result[0][0][50, 195])

    def test_adjacent_food_or_a_tiny_sauce_speck_does_not_validate_dish(self):
        dish = np.zeros((100, 100), bool)
        dish[20:80, 20:80] = True
        adjacent = np.zeros_like(dish)
        adjacent[30:70, 78:98] = True
        speck = np.zeros_like(dish)
        speck[50, 50] = True
        for food in (adjacent, speck):
            self.assertEqual(prepare_dish_candidates(
                [(dish, .99)], 100, 100, food_candidates=[(food, .9)],
            ), [])

    def test_narrow_border_sliver_is_rejected_before_outline_completion(self):
        sliver = np.zeros((100, 100), bool)
        sliver[0:100, 0:10] = True
        with patch("image_contract._dish_silhouette_from_bounds") as complete:
            self.assertEqual(prepare_dish_candidates([(sliver, .99)], 100, 100), [])
        complete.assert_not_called()

    def test_contained_high_confidence_fragment_does_not_replace_full_dish(self):
        dish = np.zeros((100, 100), bool)
        dish[10:90, 10:90] = True
        fragment = np.zeros_like(dish)
        fragment[10:90, 10:20] = True
        result = encode_plates([(fragment, .99), (dish, .8)], 100, 100)
        self.assertEqual(len(result["plates"]), 1)
        self.assertEqual(result["plates"][0]["bounds"], [.1, .1, .8, .8])

    def test_two_food_filled_overlapping_dishes_stay_separate(self):
        a = np.zeros((100, 200), bool)
        b = np.zeros_like(a)
        a[10:90, 10:100] = True
        b[10:90, 80:170] = True
        fa, fb = np.zeros_like(a), np.zeros_like(a)
        fa[35:65, 35:65] = True
        fb[35:65, 120:150] = True
        dishes = prepare_dish_candidates([(a, .9), (b, .85)], 200, 100,
                                         food_candidates=[(fa, .9), (fb, .9)])
        self.assertEqual(len(encode_plates(dishes, 200, 100)["plates"]), 2)

    def test_food_mask_validation(self):
        dish = np.ones((100, 100), bool)
        for mask, score in [(np.ones((99, 100)), .9), (dish, float("nan"))]:
            with self.assertRaises(ValueError):
                prepare_dish_candidates([(dish, .9)], 100, 100,
                                        food_candidates=[(mask, score)])

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
