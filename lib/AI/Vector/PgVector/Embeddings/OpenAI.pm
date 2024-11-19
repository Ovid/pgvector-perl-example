use v5.40.0;

use experimental 'class';

class AI::Vector::PgVector::Embeddings::OpenAI {
    use JSON::MaybeXS qw(decode_json);
    use OpenAPI::Client::OpenAI;
    use Carp                        qw(carp croak);
    use AI::Vector::PgVector::Types qw(
      compile
      ArrayRef
      Enum
      NonEmptyStr
    );
    use Data::Printer;

    field $verbose :param :reader = 0;
    field $model :param :reader   = 'text-embedding-3-small';
    field $openai                 = OpenAPI::Client::OpenAI->new;

    ADJUST {
        state @allowed_models = qw(
          text-embedding-3-small
          text-embedding-3-large
          text-embedding-ada-002
        );
        state $models = Enum [@allowed_models];
        unless ( $models->check($model) ) {
            my $allowed = join ', ', @allowed_models;
            croak "Invalid model: $model. Allowed values: $allowed\n";
        }
    }

    method get_embeddings($texts) {
        state $check = compile( NonEmptyStr | ArrayRef [NonEmptyStr] );
        ($texts) = $check->($texts);

        my $response = $openai->createEmbedding(
            {
                body => {
                    input => $texts,
                    model => "text-embedding-3-small"
                }
            },
        );

        if ($verbose) {
            p $response;
        }

        if ( $response->res->is_success ) {
            try {
                my $result
                  = decode_json( $response->res->content->asset->slurp );
                my $data       = $result->{data};
                my @embeddings = map { $_->{embedding} } $data->@*;
                return \@embeddings;
            }
            catch ($error) {
                croak "Error decoding JSON response from OpenAI: $error";
            }
        }
        else {
            my $res = $response->res;
            croak "Failed to get embeddings from OpenAI: " . $res->to_string;
        }
    }
}

__END__

=head1 NAME

Vector::PgVector::Embeddings::OpenAI - Get embeddings from OpenAI

=head1 SYNOPSIS

    use Vector::PgVector::Embeddings::OpenAI;

    my $openai = Vector::PgVector::Embeddings::OpenAI->new;

    my $embeddings = $openai->get_embeddings(['Hello, world!']);

    use DDP;
    p $embeddings;

=head1 DESCRIPTION

This module provides a simple interface to the OpenAI API for text embeddings.

=head1 METHODS

=head2 new

    my $openai = Vector::PgVector::Embeddings::OpenAI->new;

Creates a new instance of the OpenAI client.

=head3 Arguments

=over 4

=item * C<verbose> - If set to a true value, will print debugging information.

=item * C<model> - The model to use. Defaults to C<text-embedding-3-small>.

=back

=head3 Models

The following models are available:

=over 4

=item * C<text-embedding-3-small>

=item * C<text-embedding-3-large>

=item * C<text-embedding-ada-002>

=back

You can read more about them at L<https://platform.openai.com/docs/api-reference/embeddings>.

=head2 get_embeddings

    my $embeddings = $openai->get_embeddings(['Hello, world!']);

Given an arrayref of strings, returns an arrayref of embeddings.

You may also pass an arrayref of arrayref of strings and it will return an 
arrayref of arrayref of embeddings.
