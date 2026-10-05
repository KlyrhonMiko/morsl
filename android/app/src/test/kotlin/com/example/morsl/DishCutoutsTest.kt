package com.example.morsl

import org.junit.Assert.*
import org.junit.Test

class DishCutoutsTest {
    @Test fun separateDishesSurviveDuplicateAndNestedCupSuppression() {
        val plate = DishCutouts.Box(.1f,.1f,.6f,.5f,.9f)
        val duplicate = plate.copy(l=.11f, score=.7f)
        val cup = DishCutouts.Box(.3f,.2f,.4f,.3f,.95f)
        val other = DishCutouts.Box(.4f,.4f,.9f,.9f,.8f)
        assertEquals(listOf(plate, other), DishCutouts.selectBoxes(listOf(cup, duplicate, other, plate)))
    }
    @Test fun fillsFoodHolesAndRemovesUnrelatedFragments() {
        val w=9; val h=8; val mask=BooleanArray(w*h)
        for (y in 2..5) for (x in 2..6) mask[y*w+x]=true
        mask[3*w+4]=false
        mask[0]=true
        DishCutouts.cleanMask(mask,w,h)
        assertEquals(20,mask.count { it })
        assertTrue(mask[3*w+4]);assertFalse(mask[0]);assertFalse(mask[7*w+8])
    }
    @Test fun emptyMaskStaysEmptyAndClippedDishKeepsItsEdge() {
        val empty=BooleanArray(30)
        DishCutouts.cleanMask(empty,6,5);assertFalse(empty.any { it })
        val clipped=BooleanArray(30)
        for(y in 1..3) for(x in 0..2) clipped[y*6+x]=true
        DishCutouts.cleanMask(clipped,6,5);assertEquals(9,clipped.count { it })
    }
}
