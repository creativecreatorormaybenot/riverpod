part of '../../framework.dart';

/// An internal class for `ProviderBase.selectAsync`.
@sealed
class _AsyncSelector<InputT, OutputT>
    with ProviderListenable<FutureOr<OutputT>> {
  /// An internal class for `ProviderBase.select`.
  _AsyncSelector({
    required this.provider,
    required this.future,
    required this.selector,
  });

  /// The provider that was selected
  final ProviderListenable<AsyncValue<InputT>> provider;

  /// The future associated to the listened provider
  final ProviderListenable<FutureOr<InputT>> future;

  /// The selector applied
  final OutputT Function(InputT) selector;

  Result<OutputT> _select(InputT value) {
    if (kDebugMode) _debugIsRunningSelector = true;

    try {
      return Result.data(selector(value));
    } catch (err, stack) {
      return Result.error(err, stack);
    } finally {
      if (kDebugMode) _debugIsRunningSelector = false;
    }
  }

  @override
  _SelectorSubscription<AsyncValue<InputT>, FutureOr<OutputT>> addListener(
    Node node,
    void Function(FutureOr<OutputT>? previous, FutureOr<OutputT> next)
        listener, {
    required void Function(Object error, StackTrace stackTrace)? onError,
    required void Function()? onDependencyMayHaveChanged,
    required bool fireImmediately,
  }) {
    Result<OutputT>? lastSelectedValue;
    Completer<OutputT>? selectedCompleter;
    FutureOr<OutputT>? selectedFuture;

    void emitData(OutputT data, {required bool callListeners}) {
      final previousFuture = selectedFuture;
      if (selectedCompleter != null) {
        selectedCompleter!.complete(data);
        selectedCompleter = null;
      } else {
        final next = selectedFuture = data;
        if (callListeners) listener(previousFuture, next);
      }
    }

    void emitError(
      Object err,
      StackTrace? stack, {
      required bool callListeners,
    }) {
      final previousFuture = selectedFuture;
      if (selectedCompleter != null) {
        selectedCompleter!.completeError(err, stack);
        selectedCompleter = null;
      } else {
        selectedFuture = Future.error(err, stack);
        if (callListeners) listener(previousFuture, selectedFuture!);
      }
    }

    void playValue(
      AsyncValue<InputT> value, {
      bool callListeners = true,
    }) {
      void onLoading(AsyncValue<void> loading) {
        if (selectedFuture == null) {
          // The first time a future is emitted

          final completer = selectedCompleter = Completer();
          selectedFuture = completer.future;
        }

        // We don't notify listeners when the future changes since
        // they want to filter rebuilds based on the result
      }

      value.map(
        loading: onLoading,
        data: (value) {
          if (value.isRefreshing) {
            onLoading(value);
            return;
          }

          final newSelectedValue = _select(value.value);
          switch (newSelectedValue) {
            case ResultData():
              if (newSelectedValue != lastSelectedValue) {
                emitData(
                  newSelectedValue.state,
                  callListeners: callListeners,
                );
              }
            case ResultError():
              emitError(
                newSelectedValue.error,
                newSelectedValue.stackTrace,
                callListeners: callListeners,
              );
          }

          lastSelectedValue = newSelectedValue;
        },
        error: (value) {
          if (value.isRefreshing) {
            onLoading(value);
            return;
          }

          emitError(
            value.error,
            value.stackTrace,
            callListeners: callListeners,
          );

          // Error in the provider, it should've already been propagated
          // so no need to pollute the stack
          if (selectedFuture case final Future<Object?> f) f.ignore();
        },
      );
    }

    final sub = node.listen<AsyncValue<InputT>>(
      provider,
      (prev, input) => playValue(input),
      onError: onError,
      fireImmediately: false,
    );

    playValue(sub.read(), callListeners: false);

    if (fireImmediately) {
      listener(null, selectedFuture as FutureOr<OutputT>);
    }

    return _SelectorSubscription(
      node,
      sub,
      () => selectedFuture as FutureOr<OutputT>,
      onClose: () {
        final completer = selectedCompleter;
        if (completer != null && !completer.isCompleted) {
          read(node).then(
            completer.complete,
            onError: completer.completeError,
          );
        }
      },
    );
  }

  @override
  FutureOr<OutputT> read(Node node) {
    return future.read(node).then((v) => _select(v).requireState);
  }
}
