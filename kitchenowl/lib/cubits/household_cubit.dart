import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:kitchenowl/models/household.dart';
import 'package:kitchenowl/services/api/api_service.dart';
import 'package:kitchenowl/services/app_log.dart';
import 'package:kitchenowl/services/transaction_handler.dart';
import 'package:kitchenowl/services/transactions/household.dart';

class HouseholdCubit extends Cubit<HouseholdState> {
  HouseholdCubit(Household household)
      : super(HouseholdState(
          household: household,
        )) {
    refresh();
  }

  Future<void> refresh() async {
    final household = await TransactionHandler.getInstance().runTransaction(
      TransactionHouseholdGet(
        household: state.household,
      ),
    );
    if (household == null) {
      emit(NotFoundHouseholdState(household: state.household));
    } else {
      emit(state.copyWith(household: household));
    }
  }

  /// Returns false when the server didn't save it (e.g. offline).
  Future<bool> setPlannerBreakfast(bool value) async {
    bool ok;
    try {
      ok = await ApiService.getInstance()
          .setHouseholdPlannerBreakfast(state.household, value);
    } catch (e, st) {
      AppLog.warn('Saving the planner breakfast setting failed',
          error: e, stack: st);
      ok = false;
    }
    refresh().ignore();
    return ok;
  }
}

class HouseholdState extends Equatable {
  final Household household;

  const HouseholdState({
    required this.household,
  });

  HouseholdState copyWith({
    Household? household,
  }) =>
      HouseholdState(
        household: household ?? this.household,
      );

  @override
  List<Object?> get props => [household];
}

class NotFoundHouseholdState extends HouseholdState {
  const NotFoundHouseholdState({required super.household});
}
