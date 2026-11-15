from marshmallow import fields, Schema, EXCLUDE, ValidationError
from marshmallow.validate import OneOf, Range
from app.models.planner import MEALS


def _note_text(value: str) -> None:
    # marshmallow 4 ignores a validator's return value: it has to raise
    if not value or not value.strip():
        raise ValidationError("Text must not be empty.")
    if len(value) > 256:
        raise ValidationError("Text must be at most 256 characters.")


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
    # Move instead of add: the plan at from_cooking_date (absent = no day) and
    # from_meal is removed in the same commit, and no history is recorded
    move = fields.Boolean()
    from_cooking_date = fields.Integer()
    from_meal = fields.String(validate=OneOf(MEALS))


class AddPlannerNote(Schema):
    class Meta:
        unknown = EXCLUDE

    cooking_date = fields.Integer(required=True)
    meal = fields.String(validate=OneOf(MEALS))
    text = fields.String(required=True, validate=_note_text)


class UpdatePlannerNote(Schema):
    class Meta:
        unknown = EXCLUDE

    cooking_date = fields.Integer()
    meal = fields.String(validate=OneOf(MEALS))
    text = fields.String(validate=_note_text)


class RemovePlannedRecipe(Schema):
    class Meta:
        unknown = EXCLUDE

    cooking_date = fields.Integer()
    day = fields.Integer(
        validate=Range(min=0, min_inclusive=True, max=6, max_inclusive=True)
    )
    meal = fields.String(validate=OneOf(MEALS))
