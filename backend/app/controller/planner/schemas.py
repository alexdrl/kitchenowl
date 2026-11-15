from marshmallow import fields, Schema, EXCLUDE
from marshmallow.validate import OneOf, Range
from app.models.planner import MEALS


class AddPlannedRecipe(Schema):
    class Meta:
        unknown = EXCLUDE

    recipe_id = fields.Integer(
        required=True,
    )
    cooking_date = fields.Integer()
    day = fields.Integer(
        validate=Range(min=0, min_inclusive=True, max=6, max_inclusive=True)
    )
    yields = fields.Integer()
    meal = fields.String(validate=OneOf(MEALS))


class RemovePlannedRecipe(Schema):
    class Meta:
        unknown = EXCLUDE

    cooking_date = fields.Integer()
    day = fields.Integer(
        validate=Range(min=0, min_inclusive=True, max=6, max_inclusive=True)
    )
    meal = fields.String(validate=OneOf(MEALS))
